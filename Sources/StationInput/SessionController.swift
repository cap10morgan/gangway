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
        case peerDisconnected(name: String, reason: String?)
        /// Control moved to a peer, or came back here.
        case controlMoved(remote: Bool, peer: String?)
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

    public var clipboardSyncEnabled = false {
        didSet { clipboardSyncEnabled ? startClipboard() : clipboard.stop() }
    }

    public init(deviceName: String, identity: Identity? = nil) {
        self.deviceName = deviceName
        self.identity = identity ?? ((try? PairingStore.loadOrCreateIdentity()) ?? .generate())
        self.localDeviceID = Self.hex(self.identity.publicKeyData)
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
    }

    public func stop() {
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
    public func updateLayout(_ grid: ScreenLayoutGrid) {
        self.grid = grid
        capture?.layout = grid.layout(for: localDeviceID)
    }

    /// Peers seen on the network, so links can be opened to the ones we know.
    public func updateDiscovered(_ peers: [DiscoveredPeer]) {
        lock.lock()
        for peer in peers {
            guard let fingerprint = peer.identityFingerprint,
                  let known = PairingStore.peers().first(where: { $0.id.hasPrefix(fingerprint) })
            else { continue }
            endpoints[known.id] = peer.endpoint
            names[known.id] = peer.name
        }
        let targets = endpoints.keys.filter { links[$0] == nil && shouldInitiate(to: $0) }
        lock.unlock()

        // Reconnect to Macs already paired with. A peer that has never been paired is
        // left alone: dialling it would put an unexpected Touch ID prompt on someone
        // else's screen.
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
            self.links[id] = link
            if let expectedName { self.names[id] = expectedName }
            self.lock.unlock()
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
                } else {
                    self.onEvent?(.approvalRequested(peer: id, name: name, code: code))
                }
            case .ready:
                let id = peerID ?? ""
                let name = self.names[id] ?? expectedName ?? "another Mac"
                try? link.send(.hello, json: Hello(deviceID: UUID(),
                                                   deviceName: self.deviceName,
                                                   role: .primary))
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
        if let id { links.removeValue(forKey: id) }
        let name = id.flatMap { names[$0] } ?? "a Mac"
        lock.unlock()
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
        switch type {
        case .hello:
            let name = (try? JSONDecoder().decode(Hello.self, from: payload))?.deviceName ?? "Mac"
            if let peer {
                lock.lock(); names[peer] = name; lock.unlock()
            }
            try? link.send(.screens, json: ScreenGeometry.localScreens())

        case .screens:
            guard let peer,
                  let screens = try? JSONDecoder().decode(ScreenSet.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.capture?.setPeerBounds(screens.bounds, for: peer)
            }

        case .enterScreen:
            guard let msg = EnterScreen.decode(payload) else { return }
            injection.enter(at: NormalizedPoint(x: msg.normalizedX, y: msg.normalizedY))
            onEvent?(.controlMoved(remote: true, peer: peer.flatMap { names[$0] }))

        case .leaveScreen:
            injection.leave()
            onEvent?(.controlMoved(remote: false, peer: nil))

        case .input:
            guard let event = InputEvent.decode(payload) else { return }
            injection.inject(event)

        case .clipboard:
            receiveClipboard(payload)

        default:
            break
        }
    }

    // MARK: - Capture

    private func startCapture() {
        let capture = EventCapture(layout: grid.layout(for: localDeviceID))
        self.capture = capture

        capture.onEvent = { [weak self] event in
            guard let self, case .forwarding(let peer) = capture.mode else { return }
            self.link(for: peer)?.send(.input, event.encode())
        }
        capture.onEnterPeer = { [weak self] peer, at in
            guard let self else { return }
            self.link(for: peer)?.send(.enterScreen,
                                       EnterScreen(normalizedX: at.x, normalizedY: at.y).encode())
            self.onEvent?(.controlMoved(remote: true, peer: self.names[peer]))
        }
        capture.onReturnLocal = { [weak self] _, _ in
            guard let self else { return }
            self.allLinks().forEach { $0.send(.leaveScreen, Data()) }
            self.onEvent?(.controlMoved(remote: false, peer: nil))
        }
        capture.onEscapeHatch = { [weak self] in
            guard let self else { return }
            self.allLinks().forEach { $0.send(.leaveScreen, Data()) }
            self.onEvent?(.controlMoved(remote: false, peer: nil))
        }

        DispatchQueue.main.async { [weak self] in
            do {
                try capture.start()
            } catch {
                self?.onEvent?(.failed(error.localizedDescription))
            }
        }
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
