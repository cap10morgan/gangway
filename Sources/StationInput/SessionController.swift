import Foundation
import Network
import CoreGraphics
import StationKit

/// Owns one Mac's participation in a Station mesh.
///
/// There is no controller/controlled distinction. Every Mac listens, captures, and
/// injects; whichever Mac the pointer is currently on is the one forwarding, and that
/// changes as the pointer moves. The old primary/secondary split was an implementation
/// detail showing through the interface: both roles always needed the same permissions
/// and the same code, so the split bought nothing and forced the user to decide up
/// front which Mac they would be sitting at.
///
/// Deliberately not `@MainActor`. Forwarded input must not queue behind the UI: a hop
/// per event would add scheduling latency to every mouse move and risk reordering a
/// gesture stream.
public final class SessionController: @unchecked Sendable {

    public enum Event: Sendable {
        case listening(port: UInt16)
        /// Another Mac is asking to join. Approve with Touch ID; `code` is shown so a
        /// careful user can check it matches what the other Mac displays.
        case approvalRequested(peer: DeviceID, name: String, code: String)
        /// We asked to join another Mac. Shown passively; the approval happens there.
        case awaitingApproval(name: String, code: String)
        case paired(name: String)
        case peerConnected(name: String)
        /// A peer's real name arrived after it was stored under a placeholder.
        case peerRenamed(peer: DeviceID, name: String)
        /// A newer arrangement arrived from another Mac.
        case layoutChanged(ScreenLayoutGrid)
        /// The peer cannot keep up with what is being sent to it, so the pointer there
        /// is running behind. Reported rather than acted on: the pointer belongs to the
        /// user, and taking it back on a guess has gone badly enough already.
        case peerFallingBehind(name: String, behind: Bool)
        /// Another app has Secure Event Input on, so keystrokes cannot be forwarded.
        /// `holder` is a guess at which app it is, and may be nil; macOS does not say.
        case keyboardBlocked(holder: String?)
        /// Secure Event Input was released and keystrokes forward again.
        case keyboardUnblocked
        /// The Mac currently driving this one says its keyboard is held, or freed
        /// again. Reported here because this is the screen its user is looking at.
        case peerKeyboardBlocked(name: String, blocked: Bool)
        case peerDisconnected(name: String, reason: String?)
        /// Control moved to a peer, or came back here. Only ever emitted by the Mac
        /// that owns the physical keyboard and mouse.
        case controlMoved(remote: Bool, peer: String?)
        /// A peer's pointer arrived on this Mac, or left it again. The mirror image of
        /// `controlMoved`, and deliberately a separate case: the receiving Mac used to
        /// emit `controlMoved(remote: true)` for this, which reads as "control left
        /// here" and is the exact opposite of what happened. That put "Control is on
        /// <peer>" in the menu of the Mac being driven, and aimed a keyboard-capture
        /// warning at the one machine that captures nothing.
        case beingControlled(Bool, peer: String?)
        case failed(String)
        case clipboardSynced(sent: Bool, bytes: Int)
        case clipboardSkipped(String)
    }

    public var onEvent: (@Sendable (Event) -> Void)?

    private let deviceName: String
    private let identity: Identity
    public let localDeviceID: DeviceID

    private let lock = NSLock()
    private var listener: StationListener?
    private var capture: EventCapture?
    private let injection = EventInjection()
    private let clipboard = ClipboardMonitor()
    private var clipboardAssembler = ClipboardAssembler()
    private var clipboardTransferID: UInt64 = 0

    /// Established links, keyed by the peer's proven identity.
    private var links: [DeviceID: StationLink] = [:]
    /// Links still mid-handshake, so not yet attributable to an identity.
    private var pending: [ObjectIdentifier: StationLink] = [:]
    /// Names last seen for each peer, for user-facing messages.
    private var names: [DeviceID: String] = [:]
    /// Where each discovered peer can be reached.
    private var endpoints: [DeviceID: NWEndpoint] = [:]

    private var grid = ScreenLayoutGrid()
    /// Peers whose channel is open, so the pointer may cross to them.
    private var ready: Set<DeviceID> = []
    /// A crossing held back while a peer is asked for approval, so the push that
    /// started it can be honoured once the answer comes.
    private var heldCrossing: (peer: DeviceID, entry: NormalizedPoint)?
    /// The link input is currently being forwarded over, held directly so the hot path
    /// does not take a lock and search a dictionary for every mouse move.
    nonisolated(unsafe) private var activeLink: StationLink?
    /// Last Secure Event Input reading, and when it was taken. Any application can turn
    /// it on at any moment, including part way through a session, so checking only when
    /// control moves would miss exactly the case that is hardest to diagnose.
    nonisolated(unsafe) private var secureInputBlocked = false
    nonisolated(unsafe) private var lastSecureInputCheck = Date.distantPast
    /// Guards against control being stuck on a peer that is no longer usable.
    private var forwardingWatchdog: Timer?
    private var redialTimer: Timer?
    private var watchingDisplays = false
    nonisolated(unsafe) private var screenRefreshPending = false
    private var heartbeatTimer: Timer?
    /// When a dial to each peer was last started, so a 3s sweep cannot stack half-open
    /// connections on top of one that is still trying. `connect(to:)` only refuses when
    /// a link is already *established*, so without this the sweep opened a fresh
    /// `StationLink` every tick for as long as a dial took to fail.
    private var lastDialAt: [DeviceID: Date] = [:]
    /// When each peer's link was lost, so the Mac that loses the dial tie-break can
    /// still heal a link the other one is not healing.
    private var linkLostAt: [DeviceID: Date] = [:]
    /// When each peer last proved it was still running Station, as opposed to still
    /// holding an open socket. Maintained for every established link, not only the one
    /// being forwarded to; see the heartbeat timer in `start`.
    private var lastHeartbeatReply: [DeviceID: Date] = [:]
    /// When anything at all last arrived from a peer. Any frame proves Station is alive
    /// there, so this is broader evidence than a heartbeat reply and costs nothing.
    private var lastInbound: [DeviceID: Date] = [:]
    /// Peers that have actually answered a heartbeat at least once.
    ///
    /// Silence is only evidence of death from a peer that has been shown to speak.
    /// Without this gate the check condemns every peer running a build older than the
    /// heartbeat itself: they ignore an unknown message type, never reply, and get
    /// their control yanked away mid-use every few seconds. That is a worse failure
    /// than the one the heartbeat was added to prevent, and it is self-inflicted --
    /// a new version of Station must not decide that an old one is dead.
    private var speaksHeartbeat: Set<DeviceID> = []

    /// How long the send backlog must stay full before the user is told. Long enough
    /// that a momentary stall during a heavy gesture is not worth mentioning.
    private static let congestionGrace: TimeInterval = 3
    nonisolated(unsafe) private var congestedSince: Date?
    nonisolated(unsafe) private var peerIsBehind = false

    /// `CGEventType.mouseMoved`. The only event Station will discard.
    private static let mouseMovedType: UInt32 = 5

    private static let heartbeatRequest: UInt8 = 0
    private static let heartbeatReply: UInt8 = 1
    /// Deliberately long, because the two failure modes are not symmetric.
    ///
    /// Reclaiming late costs the user a few seconds in front of an unresponsive peer,
    /// and Control-Option-Escape already gets them out of that immediately. Reclaiming
    /// wrongly snatches the pointer mid-use and parks it back at the screen edge, which
    /// reads as the cursor being broken rather than as a peer problem -- and it happens
    /// while the user is actively working, not while they are already stuck.
    ///
    /// Six seconds proved too eager against a peer that was alive: replies are handled
    /// in frame order on the connection's receive queue, behind however many input
    /// events are already queued for injection, so this measures round-trip latency
    /// under load as much as it measures liveness. Fifteen seconds of total silence
    /// from a Mac that is being actively driven is not something latency explains.
    private static let heartbeatDeadline: TimeInterval = 15

    public var clipboardSyncEnabled = false {
        didSet { clipboardSyncEnabled ? startClipboard() : clipboard.stop() }
    }

    public init(deviceName: String, identity: Identity? = nil) {
        self.deviceName = deviceName
        self.identity = identity ?? ((try? PairingStore.loadOrCreateIdentity()) ?? .generate())
        self.localDeviceID = Self.hex(self.identity.publicKeyData)
    }

    /// Set STATION_DEBUG_EVENTS=1 to log what is forwarded and what arrives, by type.
    /// Counting rather than logging each event, because forwarding runs at pointer
    /// rates and per-event logging would itself change the timing being investigated.
    /// Guarded: `note` is called from the tap thread when sending and from the network
    /// queue when receiving, so these were being mutated from two threads at pointer
    /// rates. Concurrent Dictionary mutation is undefined behaviour, and instrumentation
    /// that destabilises the thing it measures is worse than none.
    nonisolated(unsafe) private static var sentCounts: [UInt32: Int] = [:]
    nonisolated(unsafe) private static var recvCounts: [UInt32: Int] = [:]
    nonisolated(unsafe) private static var lastReport = Date()
    private static let countsLock = NSLock()
    /// Enabled by environment for the CLI, or by
    /// `defaults write com.station.Station STATION_DEBUG_EVENTS -bool YES` for the app,
    /// which has no console to read.
    private static let debugEvents =
        ProcessInfo.processInfo.environment["STATION_DEBUG_EVENTS"] == "1"
        || UserDefaults.standard.bool(forKey: "STATION_DEBUG_EVENTS")

    /// ~/Library/Logs/Station.log, not the temp directory. The temp path differs per
    /// user and per launch context, so "tail the log" turned into a hunt for the file.
    private static let debugLogURL: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Station.log")
    }()

    /// Appends rather than printing: the app writes nowhere a user can see.
    static func debugLog(_ line: String) {
        guard debugEvents else { return }
        let stamped = "\(Date().formatted(date: .omitted, time: .standard))  \(line)\n"
        if let handle = try? FileHandle(forWritingTo: debugLogURL) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: debugLogURL, atomically: true, encoding: .utf8)
        }
    }

    nonisolated(unsafe) private static var droppedCount = 0
    nonisolated(unsafe) private static var injectTotalNanos: UInt64 = 0
    nonisolated(unsafe) private static var injectPeakNanos: UInt64 = 0
    nonisolated(unsafe) private static var injectSamples = 0

    private static func note(injectionNanos: UInt64) {
        countsLock.lock()
        injectTotalNanos += injectionNanos
        injectPeakNanos = max(injectPeakNanos, injectionNanos)
        injectSamples += 1
        countsLock.unlock()
    }

    /// Counted, not logged per event: shedding happens at pointer rates by definition.
    private static func note(dropped: Bool) {
        guard debugEvents else { return }
        countsLock.lock()
        droppedCount += 1
        countsLock.unlock()
    }

    private static func note(sent: UInt32?, received: UInt32?) {
        // Checked before taking the lock so this costs nothing when logging is off,
        // which is the case that runs on the input hot path.
        guard debugEvents else { return }

        countsLock.lock()
        if let sent { sentCounts[sent, default: 0] += 1 }
        if let received { recvCounts[received, default: 0] += 1 }
        guard Date().timeIntervalSince(lastReport) > 1 else {
            countsLock.unlock()
            return
        }
        lastReport = Date()
        let sentSnapshot = sentCounts
        let recvSnapshot = recvCounts
        let dropped = droppedCount
        let injectTotal = injectTotalNanos
        let injectPeak = injectPeakNanos
        let injectN = injectSamples
        sentCounts.removeAll()
        recvCounts.removeAll()
        droppedCount = 0
        injectTotalNanos = 0
        injectPeakNanos = 0
        injectSamples = 0
        countsLock.unlock()

        func render(_ counts: [UInt32: Int]) -> String {
            counts.isEmpty ? "-" : counts.sorted { $0.key < $1.key }
                .map { "\(typeName($0.key))=\($0.value)" }.joined(separator: " ")
        }
        // Writing to disk outside the lock, and off the thread that delivered the event.
        var line = "sent: \(render(sentSnapshot))  received: \(render(recvSnapshot))"
        if dropped > 0 { line += "  shed: \(dropped) moves (peer behind)" }
        if injectN > 0 {
            let meanMs = Double(injectTotal) / Double(injectN) / 1_000_000
            let peakMs = Double(injectPeak) / 1_000_000
            line += String(format: "  inject: mean %.2fms peak %.2fms", meanMs, peakMs)
        }
        DispatchQueue.global(qos: .utility).async { debugLog(line) }
    }

    private static func typeName(_ t: UInt32) -> String {
        switch t {
        case 1, 2: return "leftMouse"
        case 5, 6, 7, 27: return "move"
        case 10: return "keyDown"
        case 11: return "keyUp"
        case 12: return "flags"
        case 14: return "systemDefined"
        case 22: return "scroll"
        case 29: return "gesture"
        case 30: return "magnify"
        default: return "type\(t)"
        }
    }

    public static func hex(_ data: Data) -> DeviceID {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public var publicIdentity: Data { identity.publicKeyData }

    // MARK: - Lifecycle

    /// Begin listening, capturing, and reconnecting to known peers.
    public func start(grid: ScreenLayoutGrid) {
        stop()
        self.grid = grid

        let listener = StationListener(deviceName: deviceName, identity: identity)
        listener.onError = { [weak self] in self?.onEvent?(.failed($0.localizedDescription)) }
        listener.onReady = { [weak self] port in self?.onEvent?(.listening(port: port.rawValue)) }
        listener.onLink = { [weak self] link in self?.adopt(link, expectedName: nil) }
        do {
            try listener.start()
            self.listener = listener
        } catch {
            onEvent?(.failed(error.localizedDescription))
            return
        }
        startCapture()
        watchDisplays()

        // Reconnecting must not depend on someone else raising an event; see
        // `redialKnownPeers`. Cheap: it does nothing at all unless a paired Mac we know
        // an address for has no link.
        redialTimer?.invalidate()
        redialTimer = Timer.scheduledTimer(withTimeInterval: Self.redialInterval,
                                           repeats: true) { [weak self] _ in
            self?.redialKnownPeers()
        }

        // Heartbeats used to be sent only from the forwarding watchdog, which runs only
        // while this Mac is actually driving another one. Two consequences, both bad.
        // An idle link exchanged nothing at all, so it was TCP keepalive alone that
        // decided whether the peer still existed -- the one job it is unfit for. And
        // `speaksHeartbeat` could only ever be populated during forwarding, so the
        // watchdog's own liveness check was usually disarmed at the moment it was
        // needed, having never seen the peer answer. Liveness is a property of the
        // link, not of what the link happens to be carrying.
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval,
                                              repeats: true) { [weak self] _ in
            self?.pingPeers()
        }
    }

    // MARK: - Displays

    /// Keep screen geometry current when monitors are attached, detached or rearranged.
    ///
    /// Geometry used to be read once, when capture was created. `refreshScreens` existed
    /// on both capture and injection but nothing ever called it, so after plugging in
    /// or unplugging a monitor this Mac kept watching the old edges -- pushing at the
    /// real edge did nothing -- and kept placing injected input by the old arrangement,
    /// while the other Mac mapped the pointer onto screens that were no longer there.
    /// Only restarting Station fixed it.
    private func watchDisplays() {
        guard !watchingDisplays else { return }
        watchingDisplays = true
        CGDisplayRegisterReconfigurationCallback(stationDisplayReconfigured,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }

    private func stopWatchingDisplays() {
        guard watchingDisplays else { return }
        watchingDisplays = false
        CGDisplayRemoveReconfigurationCallback(stationDisplayReconfigured,
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    /// One change is reported once per affected display, so attaching a dock with two
    /// monitors arrives as a burst. Coalesce it into one refresh.
    fileprivate func displaysChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.screenRefreshPending else { return }
            self.screenRefreshPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.applyDisplayChange()
            }
        }
    }

    private func applyDisplayChange() {
        screenRefreshPending = false
        let screens = ScreenGeometry.localScreens()
        let b = screens.bounds
        capture?.refreshScreens()
        injection.refreshScreens()
        Self.debugLog(String(format: "displays changed; screen area now %.0f,%.0f to %.0f,%.0f",
                             b.minX, b.minY, b.maxX, b.maxY))
        // The other Macs map the pointer onto our screens using the geometry we sent
        // when the link opened. Send it again, or they keep aiming at the old ones.
        for link in allLinks() {
            try? link.send(.screens, json: screens)
        }
    }

    /// Ask every established peer to prove Station is still running there.
    private func pingPeers() {
        lock.lock()
        let live = ready.compactMap { links[$0] }
        lock.unlock()
        for link in live {
            link.send(.heartbeat, Data([Self.heartbeatRequest]))
        }
    }

    /// Frequent enough to keep an idle link warm and to notice a peer going away
    /// well inside `heartbeatDeadline`.
    private static let heartbeatInterval: TimeInterval = 5

    /// Slow enough to be invisible when everything is fine, quick enough that a dropped
    /// link heals before it is worth complaining about.
    private static let redialInterval: TimeInterval = 3

    public func stop() {
        stopWatchingDisplays()
        redialTimer?.invalidate()
        redialTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        forwardingWatchdog?.invalidate()
        forwardingWatchdog = nil
        clipboard.stop()
        if let capture {
            if Thread.isMainThread { capture.stop() }
            else { DispatchQueue.main.sync { capture.stop() } }
        }
        capture = nil
        lock.lock()
        let all = Array(links.values) + Array(pending.values)
        links.removeAll()
        pending.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
        listener?.stop()
        listener = nil
    }

    /// Re-apply the arrangement without tearing down connections.
    ///
    /// - Parameter broadcast: whether to tell the other Macs. False when applying an
    ///   arrangement that came *from* a peer, which would otherwise echo back and
    ///   forth between them forever.
    public func updateLayout(_ grid: ScreenLayoutGrid, broadcast: Bool = true) {
        self.grid = grid
        capture?.layout = grid.layout(for: localDeviceID)
        guard broadcast else { return }
        for link in allLinks() {
            try? link.send(.layout, json: grid)
        }
    }

    /// Peers seen on the network, so links can be opened to the ones we know.
    public func updateDiscovered(_ peers: [DiscoveredPeer]) {
        lock.lock()
        // Every discovered Mac, not only paired ones: the pointer can be pushed at a
        // Mac that has never been paired, and that is what starts the pairing.
        for peer in peers {
            // Never treat our own advertisement as a peer: it would put this Mac in its
            // own arrangement twice and let it try to connect to itself.
            guard let id = peer.deviceID, id != localDeviceID else { continue }
            endpoints[id] = peer.endpoint
            names[id] = peer.name
        }
        lock.unlock()
        redialKnownPeers()
    }

    /// Dial every paired Mac we know an address for and have no link to.
    ///
    /// Called both when Bonjour reports a change and on a timer, and the timer is the
    /// important one. Discovery only fires when the browse *results* change, so a link
    /// that dies while the peer keeps advertising -- a network blip, a peer process
    /// that restarts inside the record's lifetime, a record held up by a sleep proxy --
    /// produced no callback at all. Station would sit with a cached endpoint and no
    /// link and never dial it, which is why the fix that worked was sleeping both Macs:
    /// that churns the Bonjour record and re-fires the browse. Reconnecting is idle
    /// work, so it should not need an external event to notice it is owed.
    private func redialKnownPeers() {
        lock.lock()
        let now = Date()
        let targets = endpoints.keys.filter { peer in
            guard links[peer] == nil else { return false }
            // One dial at a time. A dial can take `connectionTimeout` to fail, which is
            // several sweeps' worth.
            if let last = lastDialAt[peer], now.timeIntervalSince(last) < Self.dialCooldown {
                return false
            }
            // The tie-break stops both Macs dialling at once on a healthy start-up, but
            // as a *recovery* gate it meant only one of the two could ever repair a
            // link -- and if that one was the Mac having the problem, nothing repaired
            // it. So the loser dials too, just later: long enough that the winner's
            // attempt normally lands first, short enough to still be a recovery.
            if shouldInitiate(to: peer) { return true }
            return linkLostAt[peer].map {
                now.timeIntervalSince($0) > Self.opposingRedialDelay
            } ?? false
        }
        for peer in targets { lastDialAt[peer] = now }
        lock.unlock()
        guard !targets.isEmpty else { return }

        // A peer that has never been paired is left alone: dialling it would put an
        // unexpected Touch ID prompt on someone else's screen.
        let known = Set(PairingStore.peers().map(\.id))
        for id in targets where known.contains(id) {
            connect(to: id)
        }
    }

    /// Deterministic tie-break so two Macs do not dial each other simultaneously and
    /// end up with a redundant pair of links.
    private func shouldInitiate(to peer: DeviceID) -> Bool {
        localDeviceID < peer
    }

    /// Which of two links to the same peer to keep, decided only from facts both Macs
    /// agree on, so both ends always keep the same TCP connection.
    ///
    /// A link dialled by the lower-ID Mac -- the tie-break winner -- beats one dialled
    /// by the other side. If the same Mac dialled both, the newer one wins: a Mac only
    /// dials a peer it has no link to, so a second dial means it gave up on the first,
    /// and the other end should follow rather than cling to a connection its peer has
    /// already abandoned. Both dials come from one Mac and are at least `dialCooldown`
    /// apart, so both ends see them in the same order.
    static func keepsNewcomer(incumbentDialledByLowerID: Bool,
                              newcomerDialledByLowerID: Bool) -> Bool {
        if incumbentDialledByLowerID != newcomerDialledByLowerID {
            return newcomerDialledByLowerID
        }
        return true
    }

    private static let dialCooldown: TimeInterval = 12
    private static let opposingRedialDelay: TimeInterval = 15

    /// Dial a Mac we have not paired with yet, identified only by the fingerprint it
    /// advertises. Its full identity is learned during the handshake.
    public func connectByFingerprint(_ fingerprint: String, endpoint: NWEndpoint, name: String) {
        lock.lock()
        let already = links.values.contains { _ in false }
        lock.unlock()
        guard !already else { return }
        let link = StationLink(endpoint: endpoint, identity: identity, expectedPeerIdentity: nil)
        adopt(link, expectedName: name)
        link.start()
    }

    /// Open a link to a peer, pairing if this is the first time.
    public func connect(to peer: DeviceID) {
        lock.lock()
        let endpoint = endpoints[peer]
        let alreadyLinked = links[peer] != nil
        lock.unlock()
        guard let endpoint, !alreadyLinked else { return }

        let pinned = PairingStore.peers().first { $0.id == peer }?.publicKey
        let link = StationLink(endpoint: endpoint, identity: identity,
                               expectedPeerIdentity: pinned)
        adopt(link, expectedName: names[peer])
        link.start()
    }

    // MARK: - Links

    private func adopt(_ link: StationLink, expectedName: String?) {
        lock.lock()
        pending[ObjectIdentifier(link)] = link
        lock.unlock()

        nonisolated(unsafe) var peerID: DeviceID?

        link.onPeerApproved = { [weak self] in
            guard let self else { return }
            link.confirmPairing()
            let id = peerID ?? ""
            let name = self.names[id] ?? expectedName ?? "another Mac"
            if let key = Data(hexString: id), !id.isEmpty,
               PairingStore.peers().first(where: { $0.id == id }) == nil {
                PairingStore.upsert(PairingStore.Peer(publicKey: key, name: name, edge: .right))
            }
            self.onEvent?(.paired(name: name))
        }

        link.onPeerIdentity = { [weak self] key, known in
            guard let self else { return }
            let id = Self.hex(key)
            peerID = id
            self.lock.lock()
            self.pending.removeValue(forKey: ObjectIdentifier(link))
            // Two links to one peer: both Macs must keep the *same* one.
            //
            // The previous rule kept whichever link this Mac happened to learn about
            // first. That is local knowledge, and the other Mac can learn about them in
            // the opposite order -- so each end kept a different TCP connection and
            // cancelled the one the other end was using. Both died, both redialled, and
            // it repeated: 47 cancellations in four days, most exactly one redial cycle
            // (17-19s) apart. It also meant a fresh link from a Mac that had given up on
            // a black-holed one was thrown away in favour of the black hole, which is
            // what stretched the stall on 14 September out until TCP finally gave up.
            var replaced: StationLink?
            var keepNew = true
            if let incumbent = self.links[id], incumbent !== link {
                keepNew = Self.keepsNewcomer(
                    incumbentDialledByLowerID: incumbent.isInitiator == self.shouldInitiate(to: id),
                    newcomerDialledByLowerID: link.isInitiator == self.shouldInitiate(to: id))
                if keepNew {
                    replaced = incumbent
                    // Forwarding follows the link. Sends made before the new link's
                    // channel opens are queued and delivered in order, not dropped.
                    if self.activeLink === incumbent { self.activeLink = link }
                }
            }
            if keepNew { self.links[id] = link }
            if let expectedName { self.names[id] = expectedName }
            self.lock.unlock()
            let name = self.names[id] ?? id
            if !keepNew {
                Self.debugLog("redundant link to \(name) cancelled (kept the existing one)")
                link.cancel()
                return
            }
            if let replaced {
                // Already unmapped, so its own teardown reads as stale and leaves the
                // peer's state alone.
                Self.debugLog("link to \(name) replaced by a newer one both Macs agree on")
                replaced.cancel()
            }
            _ = known
        }

        link.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .awaitingConfirmation(let code):
                let id = peerID ?? ""
                let name = self.names[id] ?? expectedName ?? "another Mac"
                if link.isInitiator {
                    // We asked to join, so a person approves on the other Mac. Do NOT
                    // open the channel yet: confirming here is what allows incoming
                    // input, and doing it up front would let whoever answered control
                    // this Mac before anyone approved anything. Wait for word back.
                    self.onEvent?(.awaitingApproval(name: name, code: code))
                } else if PairingStore.peers().contains(where: { $0.id == id }) {
                    // Already paired. The handshake verified a signature over this
                    // session's transcript with that exact key, so the peer has proven
                    // it is the Mac we pinned; asking again would train the user to
                    // approve prompts without reading them.
                    link.confirmPairing()
                    link.announceApproval()
                    Self.debugLog("peer \(name) connected")
                self.onEvent?(.peerConnected(name: name))
                } else {
                    self.onEvent?(.approvalRequested(peer: id, name: name, code: code))
                }
            case .ready:
                let id = peerID ?? ""
                let name = self.names[id] ?? expectedName ?? "another Mac"
                try? link.send(.hello, json: Hello(deviceID: UUID(),
                                                   deviceName: self.deviceName,
                                                   role: .primary))
                // Offer ours; whichever copy is newer wins, so a Mac that has been
                // away comes back into step without anyone rearranging anything.
                try? link.send(.layout, json: self.grid)
                Self.debugLog("peer \(name) connected")
                self.onEvent?(.peerConnected(name: name))
            case .failed(let reason):
                self.drop(link, id: peerID, reason: reason)
            case .cancelled:
                self.drop(link, id: peerID, reason: nil)
            case .connecting, .handshaking:
                break
            }
        }

        link.onMessage = { [weak self] type, payload in
            self?.handle(type: type, payload: payload, link: link, peer: peerID)
        }
    }

    private func drop(_ link: StationLink, id: DeviceID?, reason: String?) {
        lock.lock()
        pending.removeValue(forKey: ObjectIdentifier(link))
        var wasActive = false
        // Only the link that is *currently* the peer's link may clear that peer's state.
        // Without this check a stale duplicate dying tore down the live connection's
        // bookkeeping -- removing it from `links` and `ready`, logging a disconnect, and
        // prompting the sweep to dial yet another link -- while the real one carried on
        // delivering input. The symptom is unmistakable once you know it: a disconnect
        // in the log with no interruption whatsoever in the event stream around it.
        let isCurrent = id.map { links[$0] === link } ?? false
        if let id, isCurrent {
            if links[id] === activeLink {
                activeLink = nil
                wasActive = true
            }
            links.removeValue(forKey: id)
            ready.remove(id)
            lastHeartbeatReply.removeValue(forKey: id)
            lastInbound.removeValue(forKey: id)
            speaksHeartbeat.remove(id)
            if heldCrossing?.peer == id { heldCrossing = nil }
            linkLostAt[id] = Date()
        }
        let name = id.flatMap { names[$0] } ?? "a Mac"
        lock.unlock()

        // Take control back. Clearing the link alone left the capture forwarding to a
        // peer that is gone: every keystroke and mouse move was still being swallowed
        // locally and sent nowhere, so the Mac appeared dead until the escape hatch was
        // found. A peer that disappears must hand control back, not take it with it.
        if wasActive {
            DispatchQueue.main.async { [weak self] in
                self?.capture?.returnControlLocally()
            }
            onEvent?(.controlMoved(remote: false, peer: nil))
        }
        guard isCurrent || id == nil else {
            Self.debugLog("stale link to \(name) closed; live link unaffected")
            return
        }
        Self.debugLog("peer \(name) disconnected\(reason.map { ": \($0)" } ?? "")"
                    + (wasActive ? " while it held control" : ""))
        onEvent?(.peerDisconnected(name: name, reason: reason))
    }

    /// Called after the person here has authenticated.
    public func approve(peer: DeviceID) {
        lock.lock()
        let link = links[peer]
        lock.unlock()
        guard let link else { return }
        link.confirmPairing()
        // Tell the other Mac it may open its side too.
        link.announceApproval()

        let name = names[peer] ?? "Mac"
        if PairingStore.peers().first(where: { $0.id == peer }) == nil,
           let key = Data(hexString: peer) {
            PairingStore.upsert(PairingStore.Peer(publicKey: key, name: name,
                                                  edge: .right))
        }
        onEvent?(.paired(name: name))
    }

    public func decline(peer: DeviceID) {
        lock.lock()
        let link = links[peer]
        lock.unlock()
        link?.cancel()
    }

    private func handle(type: MessageType, payload: Data, link: StationLink, peer: DeviceID?) {
        // Any frame at all proves Station is running over there. Recorded before the
        // switch so it covers message types added later without anyone remembering to.
        if let peer {
            lock.lock()
            lastInbound[peer] = Date()
            lock.unlock()
        }

        switch type {
        case .hello:
            guard let name = (try? JSONDecoder().decode(Hello.self, from: payload))?.deviceName,
                  !name.isEmpty else {
                try? link.send(.screens, json: ScreenGeometry.localScreens())
                return
            }
            if let peer {
                lock.lock(); names[peer] = name; lock.unlock()
                // A peer may have been stored under a placeholder, because pairing can
                // complete before its name is known. The name arrives here, so correct
                // the record rather than leaving "Mac" in the arrangement forever.
                if let stored = PairingStore.peers().first(where: { $0.id == peer }),
                   stored.name != name {
                    PairingStore.upsert(PairingStore.Peer(publicKey: stored.publicKey,
                                                          name: name,
                                                          edge: stored.edge,
                                                          pairedAt: stored.pairedAt))
                    onEvent?(.peerRenamed(peer: peer, name: name))
                }
            }
            try? link.send(.screens, json: ScreenGeometry.localScreens())

        case .screens:
            guard let peer,
                  let screens = try? JSONDecoder().decode(ScreenSet.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.capture?.setPeerBounds(screens.bounds, for: peer)
                // Only now can the pointer actually land somewhere sensible there.
                self?.markReady(peer)
            }

        case .heartbeat:
            // One byte distinguishes the two directions, so an echo cannot be mistaken
            // for a request and bounce between the two Macs forever.
            guard let first = payload.first else { return }
            if first == Self.heartbeatRequest {
                link.send(.heartbeat, Data([Self.heartbeatReply]))
            } else if let peer {
                lock.lock()
                lastHeartbeatReply[peer] = Date()
                speaksHeartbeat.insert(peer)
                lock.unlock()
            }

        case .enterScreen:
            guard let msg = EnterScreen.decode(payload) else { return }
            injection.enter(at: NormalizedPoint(x: msg.normalizedX, y: msg.normalizedY))
            onEvent?(.beingControlled(true, peer: peer.flatMap { names[$0] }))

        case .leaveScreen:
            injection.leave()
            onEvent?(.beingControlled(false, peer: nil))

        case .input:
            guard let event = InputEvent.decode(payload) else { return }
            Self.note(sent: nil, received: event.eventType)
            // Timed because injection is the suspected bottleneck and, until now, that
            // was only ever a theory. This runs synchronously before the next frame is
            // read, so whatever it costs is exactly the rate limit of the whole link.
            let started = Self.debugEvents ? DispatchTime.now().uptimeNanoseconds : 0
            let ok = injection.inject(event)
            if Self.debugEvents {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                Self.note(injectionNanos: elapsed)
            }
            if !ok {
                Self.debugLog("could not rehydrate type \(event.eventType)")
            }

        case .layout:
            guard let incoming = try? JSONDecoder().decode(ScreenLayoutGrid.self, from: payload),
                  self.grid.isSuperseded(by: incoming) else { return }
            self.grid = incoming
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.capture?.layout = incoming.layout(for: self.localDeviceID)
            }
            onEvent?(.layoutChanged(incoming))

        case .clipboard:
            receiveClipboard(payload)

        case .keyboardState:
            guard let peer,
                  let state = try? JSONDecoder().decode(KeyboardState.self, from: payload)
            else { return }
            onEvent?(.peerKeyboardBlocked(name: names[peer] ?? "The other Mac",
                                          blocked: state.blocked))

        default:
            break
        }
    }

    // MARK: - Capture

    private func startCapture() {
        // Keyboard events reach a tap only with Input Monitoring; Accessibility alone
        // gets the tap created and mouse events flowing. Missing it looks exactly like
        // "the pointer moves but nothing types".
        let permissions = Permissions.current()
        Self.debugLog("capture starting: accessibility=\(permissions.accessibility) "
                    + "inputMonitoring=\(permissions.inputMonitoring) "
                    + "secureInput=\(SecureInput.isEnabled)")
        let capture = EventCapture(layout: grid.layout(for: localDeviceID))
        self.capture = capture

        capture.isPeerReady = { [weak self] peer in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.ready.contains(peer)
        }
        capture.onPeerNotReady = { [weak self] peer, entry in
            self?.requestControl(of: peer, entry: entry)
        }
        // The hot path: one send, no lock, no lookup.
        capture.onEvent = { [weak self] event in
            Self.note(sent: event.eventType, received: nil)
            guard let self else { return }
            // Only on key events, and at most every two seconds: pointer motion far
            // outnumbers keystrokes, and this must not cost anything on that path.
            //
            // This can only ever notice a *release*: while Secure Event Input is on,
            // no key event reaches the tap, so there is nothing here to trigger on.
            // Noticing it being turned on is the watchdog's job.
            if event.eventType == 10 || event.eventType == 11 {
                self.checkSecureInput()
            }
            guard let link = self.activeLink else { return }

            // Shed pointer motion when the peer cannot keep up.
            //
            // The receiving Mac injects each event synchronously before reading the
            // next, so sending faster than it can inject builds a backlog that nothing
            // drains. That does not degrade gracefully: the pointer over there falls
            // seconds behind and the user reads it as the cursor having disappeared,
            // not as lag. Better to arrive late-but-current than complete-but-stale.
            //
            // Only plain motion is dropped, and dropping it is lossless in the way that
            // matters: every event carries an absolute normalized position, so the very
            // next one to get through restores the pointer exactly. Nothing else is
            // ever shed -- a missing key, click, or gesture event changes meaning,
            // while a missing intermediate move changes only smoothness.
            if event.eventType == Self.mouseMovedType, link.isCongested {
                Self.note(dropped: true)
                return
            }
            link.send(.input, event.encode())
        }
        capture.onEnterPeer = { [weak self] peer, at in
            guard let self else { return }
            // Checked here rather than polled: it is only a problem while forwarding,
            // and this is the moment the user will notice keys going nowhere.
            self.checkSecureInput(throttled: false, announceIfBlocked: true)
            // Start the liveness clock fresh, so a peer is never judged on silence
            // from before it was being forwarded to.
            self.lock.lock()
            self.lastHeartbeatReply[peer] = Date()
            self.lastInbound[peer] = Date()
            self.lock.unlock()
            let link = self.link(for: peer)
            self.activeLink = link
            link?.send(.enterScreen,
                       EnterScreen(normalizedX: at.x, normalizedY: at.y).encode())
            self.onEvent?(.controlMoved(remote: true, peer: self.names[peer]))
        }
        capture.onReturnLocal = { [weak self] _, _ in
            guard let self else { return }
            self.clearCongestion()
            try? self.activeLink?.send(.keyboardState, json: KeyboardState(blocked: false))
            self.activeLink = nil
            self.allLinks().forEach { $0.send(.leaveScreen, Data()) }
            self.onEvent?(.controlMoved(remote: false, peer: nil))
        }
        capture.onEscapeHatch = { [weak self] in
            guard let self else { return }
            self.clearCongestion()
            try? self.activeLink?.send(.keyboardState, json: KeyboardState(blocked: false))
            self.activeLink = nil
            self.allLinks().forEach { $0.send(.leaveScreen, Data()) }
            self.onEvent?(.controlMoved(remote: false, peer: nil))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                try capture.start()
            } catch {
                self.onEvent?(.failed(error.localizedDescription))
                return
            }
            self.startForwardingWatchdog()
        }
    }

    /// The pointer was pushed at a peer that is not ready. Connect if needed, which
    /// puts the approval prompt on that Mac, and remember the crossing so it completes
    /// on approval rather than needing to be repeated.
    private func requestControl(of peer: DeviceID, entry: NormalizedPoint) {
        lock.lock()
        heldCrossing = (peer, entry)
        let haveLink = links[peer] != nil
        let endpoint = endpoints[peer]
        lock.unlock()

        if haveLink {
            // The crossing is held until the peer's screens arrive and `markReady` runs.
            // If they never arrive, this waits forever, so at least say that it is.
            Self.debugLog("\(names[peer] ?? peer): link exists but not ready; crossing held")
            return
        }
        guard endpoint != nil else {
            onEvent?(.failed("\(names[peer] ?? "That Mac") is not on the network."))
            return
        }
        connect(to: peer)
    }

    /// A peer became usable: mark it ready and complete any crossing that was waiting.
    private func markReady(_ peer: DeviceID) {
        lock.lock()
        ready.insert(peer)
        let held = heldCrossing?.peer == peer ? heldCrossing : nil
        if held != nil { heldCrossing = nil }
        lock.unlock()

        guard let held else { return }
        DispatchQueue.main.async { [weak self] in
            self?.capture?.beginForwarding(to: held.peer, entry: held.entry)
        }
    }

    /// Return control if it is stuck on a peer that can no longer receive it.
    ///
    /// Forwarding swallows every local event, so a capture left pointing at a gone or
    /// unready peer makes the Mac look dead, or worse, quietly sends input somewhere
    /// the user is not looking. Two separate bugs produced exactly that, which is
    /// reason enough to check the invariant continuously rather than trusting every
    /// path to unwind correctly.
    private func startForwardingWatchdog() {
        forwardingWatchdog?.invalidate()
        forwardingWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let capture = self.capture,
                  case .forwarding(let peer) = capture.mode else { return }

            // Polled, and only while forwarding. Any app can turn Secure Event Input on
            // at any moment, and the instant it does, key events stop arriving at the
            // tap entirely -- so there is no event left to notice it by. Without this
            // poll the one case that actually needs reporting, it being switched on
            // mid-session, is the one case that would never be reported.
            self.checkSecureInput(throttled: false)

            self.lock.lock()
            let usable = self.links[peer] != nil && self.ready.contains(peer)
            // A peer that has not answered in time is not usable, whatever the socket
            // says. TCP keepalive is not enough on its own: a sleeping Mac behind a
            // Bonjour sleep proxy keeps answering at the network layer long after
            // Station has stopped running there, so the connection looks healthy while
            // every forwarded event goes nowhere -- and the pointer is hidden locally
            // the whole time, which is what makes this worth defending against.
            // Three conditions, all required, because reclaiming control from a peer
            // that is actually fine is itself a serious failure: it snatches the
            // pointer back mid-gesture and parks it at the screen edge.
            let answersHeartbeats = self.speaksHeartbeat.contains(peer)
            let quiet = { (stamp: Date?) in
                stamp.map { Date().timeIntervalSince($0) > Self.heartbeatDeadline } ?? false
            }
            let lastReply = self.lastHeartbeatReply[peer]
            let silent = answersHeartbeats
                && quiet(lastReply)
                && quiet(self.lastInbound[peer])
            // Read under the same lock; the link map is mutated from the network queue.
            let link = self.links[peer]
            self.lock.unlock()

            // Congestion is measured, not inferred: it is the count of frames the
            // transport has not finished writing. Sustained congestion means the peer
            // has stopped draining its socket because it cannot inject fast enough.
            let congested = link?.isCongested ?? false
            let wasBehind = self.peerIsBehind
            if congested {
                if self.congestedSince == nil { self.congestedSince = Date() }
            } else {
                self.congestedSince = nil
            }
            let behind = self.congestedSince.map {
                Date().timeIntervalSince($0) > Self.congestionGrace
            } ?? false
            if behind != wasBehind {
                self.peerIsBehind = behind
                Self.debugLog("peer \(self.names[peer] ?? peer) is "
                            + (behind ? "falling behind" : "keeping up again"))
                self.onEvent?(.peerFallingBehind(name: self.names[peer] ?? "The other Mac",
                                                 behind: behind))
            }

            guard !usable || silent else {
                // Leave a trail. A reclaim that turns out to be wrong is only
                // diagnosable if the run-up to it was recorded, and the last time this
                // fired there was nothing in the log but the reclaim itself.
                if answersHeartbeats, let last = lastReply {
                    let quietFor = Date().timeIntervalSince(last)
                    if quietFor > 4 {
                        Self.debugLog(String(format: "peer %@ has not answered for %.1fs",
                                             self.names[peer] ?? peer, quietFor))
                    }
                }
                link?.send(.heartbeat, Data([Self.heartbeatRequest]))
                return
            }

            let why = silent
                ? " (no heartbeat or traffic for \(Self.heartbeatDeadline)s)"
                : " (link gone: haveLink=\(!usable))"
            Self.debugLog("control was stuck on \(self.names[peer] ?? peer)\(why); taking it back")
            capture.returnControlLocally()
            self.activeLink = nil
            self.onEvent?(.controlMoved(remote: false, peer: nil))
        }
    }

    /// Forget congestion state, so a notice cannot outlive the session it described.
    private func clearCongestion() {
        congestedSince = nil
        guard peerIsBehind else { return }
        peerIsBehind = false
        onEvent?(.peerFallingBehind(name: "", behind: false))
    }

    /// Report Secure Event Input when it changes, in either direction.
    ///
    /// - Parameters:
    ///   - throttled: skip if checked recently. The keystroke path passes true, since
    ///     it runs once per key.
    ///   - announceIfBlocked: report even when nothing changed. Used at the moment
    ///     control crosses to a peer, where the user is about to type and needs to be
    ///     told now, not when the state last flipped.
    private func checkSecureInput(throttled: Bool = true, announceIfBlocked: Bool = false) {
        let now = Date()
        if throttled, now.timeIntervalSince(lastSecureInputCheck) < 2 { return }
        lastSecureInputCheck = now

        // Corroborated, not just the flag. See SecureInput.appearsToBlockKeyboard: the
        // flag being set does not mean our tap has stopped receiving keys, and warning
        // on it alone produced a panel insisting keystrokes were lost while the user
        // was watching them arrive.
        let blocked = SecureInput.appearsToBlockKeyboard(
            lastKeyDownAtTap: capture?.lastKeyDownAtTap)
        let changed = blocked != secureInputBlocked
        secureInputBlocked = blocked
        guard changed || (announceIfBlocked && blocked) else { return }
        Self.debugLog("secure input \(blocked ? "enabled" : "released")")
        // Tell the Mac being driven. The pointer is over there, so that is the screen
        // the user is looking at when the keyboard goes quiet; a notice only on this
        // Mac is a notice behind them.
        try? activeLink?.send(.keyboardState, json: KeyboardState(blocked: blocked))
        onEvent?(blocked ? .keyboardBlocked(holder: SecureInput.likelyHolder())
                         : .keyboardUnblocked)
    }

    private func link(for peer: DeviceID) -> StationLink? {
        lock.lock(); defer { lock.unlock() }
        return links[peer]
    }

    private func allLinks() -> [StationLink] {
        lock.lock(); defer { lock.unlock() }
        return Array(links.values)
    }

    public func installTerminationHandlers() {
        CursorControl.addTerminationCleanup { [weak self] in self?.stop() }
    }

    // MARK: - Clipboard

    private func startClipboard() {
        clipboard.onSkipped = { [weak self] in self?.onEvent?(.clipboardSkipped($0)) }
        clipboard.onLocalChange = { [weak self] content in self?.sendClipboard(content) }
        DispatchQueue.main.async { [weak self] in self?.clipboard.start() }
    }

    private func sendClipboard(_ content: ClipboardContent) {
        guard let payload = try? content.encoded() else { return }
        clipboardTransferID &+= 1
        let chunks = ClipboardTransfer.chunks(of: payload, transferID: clipboardTransferID)
        for link in allLinks() {
            for chunk in chunks { link.send(.clipboard, chunk) }
        }
        if !allLinks().isEmpty {
            onEvent?(.clipboardSynced(sent: true, bytes: payload.count))
        }
    }

    private func receiveClipboard(_ frame: Data) {
        do {
            guard let payload = try clipboardAssembler.accept(frame) else { return }
            clipboard.apply(try ClipboardContent.decode(payload))
            onEvent?(.clipboardSynced(sent: false, bytes: payload.count))
        } catch {
            onEvent?(.clipboardSkipped("could not read the clipboard from the other Mac"))
        }
    }
}

extension Data {
    /// Parse a hex identity back into bytes.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let byte = UInt8(hexString[i..<j], radix: 16) else { return nil }
            bytes.append(byte)
            i = j
        }
        self = bytes
    }
}

/// A plain function so the identical pointer can be passed to register and remove.
private func stationDisplayReconfigured(_ display: CGDirectDisplayID,
                                        _ flags: CGDisplayChangeSummaryFlags,
                                        _ userInfo: UnsafeMutableRawPointer?) {
    // Each change is reported as it begins and again when it is done; geometry read at
    // the beginning is still the old arrangement.
    guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
    Unmanaged<SessionController>.fromOpaque(userInfo).takeUnretainedValue().displaysChanged()
}
