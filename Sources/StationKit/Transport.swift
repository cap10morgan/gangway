import Foundation
import Network

public let stationBonjourType = "_station._tcp"

/// Station listens here by default rather than on an ephemeral port.
///
/// An ephemeral port changes on every restart, so any Bonjour record that outlives the
/// process points at a port nothing is listening on, and connecting to it fails with
/// ECONNREFUSED. mDNS records routinely outlive a killed process by minutes, and a
/// re-registered service takes a new name ("Mac (2)") while the dead entry lingers, so
/// the user is offered a stale choice that cannot work. A fixed port makes a stale
/// record harmless: it still points somewhere Station is listening.
public let stationDefaultPort: UInt16 = 24801

/// Builds the Network.framework parameter stack shared by both ends.
///
/// Plain TCP: confidentiality and authentication come from `SecureChannel`, not TLS.
/// The previous TLS-PSK arrangement required a shared secret before the connection
/// existed, which forced a low-entropy typed code and an offline-guessable handshake.
enum TransportParameters {

    /// Set `STATION_SIMPLE_TRANSPORT=1` to drop everything except Nagle-off.
    ///
    /// The tuning below is invisible on loopback but very much live on real Wi-Fi:
    /// `.interactiveVoice` marks packets into the WMM voice access category, which some
    /// access points handle poorly, `includePeerToPeer` allows AWDL, and the keepalive
    /// values are tight enough that a power-saving link can look dead. When a
    /// connection works locally but not between two Macs, this isolates the cause
    /// without guesswork.
    static var isSimple: Bool {
        ProcessInfo.processInfo.environment["STATION_SIMPLE_TRANSPORT"] == "1"
    }

    static func make() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Input forwarding is a latency game, not a throughput game. Nagle would
        // coalesce our tiny event frames and add up to 40ms of visible cursor lag.
        // This one is never disabled; it is the only setting that is unambiguously right.
        tcp.noDelay = true

        if !isSimple {
            tcp.enableKeepalive = true
            // Tolerate roughly 90s of silence before TCP gives up.
            //
            // These values have now been relaxed twice for the same reason, so the
            // reasoning is worth stating plainly: TCP keepalive must NOT be the thing
            // that decides a peer is gone. A Mac that dozes for twenty seconds is
            // healthy, and 10/3/3 tore the link down every time one did -- 49 timeouts
            // in a single night, each followed by a successful reconnect a second or
            // two later, which is the signature of killing a connection that was fine.
            // Liveness is the application heartbeat's job (see SessionController): it
            // can tell a napping peer from a departed one, and keepalive cannot.
            tcp.keepaliveIdle = 30
            tcp.keepaliveCount = 6
            tcp.keepaliveInterval = 10
            // Only bounds the initial handshake, not an established link.
            tcp.connectionTimeout = 10
        }

        let params = NWParameters(tls: nil, tcp: tcp)
        if !isSimple {
            params.includePeerToPeer = true
            params.serviceClass = .responsiveData
        }
        return params
    }
}

public enum LinkPhase: Sendable, Equatable {
    case connecting
    case handshaking
    /// Both Macs must display this and the user must confirm they match. Only reached
    /// on first pairing; a known peer authenticates with its pinned identity instead.
    case awaitingConfirmation(sas: String)
    case ready
    case failed(String)
    case cancelled
}

/// An authenticated, encrypted connection to one peer.
public final class StationLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let role: HandshakeRole
    private let handshake: Handshake
    private var decoder = FrameDecoder()
    private let lock = NSLock()

    private var sendCipher: CipherState?
    private var receiveCipher: CipherState?
    private var outcome: HandshakeOutcome?
    private var confirmed = false
    /// Set once a terminal phase has been reported, so consumers see it exactly once.
    private var finished = false
    /// True once the handshake begins, i.e. the connection genuinely reached the peer.
    private var reachedPeer = false
    /// Most recent reason Network.framework gave for retrying.
    private var lastWaitingReason: String?

    /// How long to sit in `.waiting` before telling the user something is wrong.
    /// Network.framework retries a blocked or unreachable endpoint indefinitely and
    /// reports only `.waiting`, so without this the UI shows "Connecting…" forever and
    /// the actual reason never surfaces.
    public static let unreachableTimeout: TimeInterval = 8
    /// App messages queued while the handshake or user confirmation is outstanding.
    private var pendingOutbound: [(MessageType, Data)] = []
    /// Decrypted messages that arrived before this side confirmed the pairing.
    ///
    /// Held rather than discarded. Each Mac confirms independently, so whichever
    /// confirms first sends immediately while the other is still waiting on its user.
    /// Dropping those messages loses the peer's `hello`, which is what triggers the
    /// screen-geometry exchange, and the session stalls with no visible error.
    private var pendingInbound: [(MessageType, Data)] = []

    /// Enough for the handshake's opening exchange, but bounded: an unconfirmed peer
    /// must not be able to make us buffer without limit.
    private static let maxPendingInbound = 32

    public var onMessage: (@Sendable (MessageType, Data) -> Void)?
    public var onPhase: (@Sendable (LinkPhase) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    /// Peer's long-term public key and whether it matched a pinned one.
    public var onPeerIdentity: (@Sendable (Data, Bool) -> Void)?
    /// A person on the other Mac authorised this pairing.
    public var onPeerApproved: (@Sendable () -> Void)?

    public var endpointDescription: String { String(describing: connection.endpoint) }

    /// True when this Mac dialled the peer. The side that dialled confirms its own
    /// pairing automatically; approval is asked for on the side that was dialled.
    public var isInitiator: Bool { role == .initiator }

    init(connection: NWConnection, queue: DispatchQueue,
         role: HandshakeRole, identity: Identity, expectedPeerIdentity: Data?) {
        self.connection = connection
        self.queue = queue
        self.role = role
        self.handshake = Handshake(role: role, identity: identity,
                                   expectedPeerIdentity: expectedPeerIdentity)
    }

    /// Dial a discovered peer.
    public convenience init(endpoint: NWEndpoint, identity: Identity,
                            expectedPeerIdentity: Data? = nil,
                            queue: DispatchQueue = .global(qos: .userInteractive)) {
        self.init(connection: NWConnection(to: endpoint, using: TransportParameters.make()),
                  queue: queue, role: .initiator, identity: identity,
                  expectedPeerIdentity: expectedPeerIdentity)
    }

    private var started = false

    /// Idempotent. A second call would attach another receive loop to the same
    /// connection, and two loops interleaving reads corrupts the frame stream.
    public func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self.reachedPeer = true
                self.lock.unlock()
                self.onPhase?(.handshaking)
                self.receiveLoop()
                // The initiator opens the handshake; the responder answers.
                if self.role == .initiator {
                    self.sendRaw(.hsEphemeral, self.handshake.ephemeralMessage())
                }
            case .waiting(let error):
                self.lock.lock()
                self.lastWaitingReason = Self.describe(error)
                self.lock.unlock()
                self.onError?(error)
                self.onPhase?(.connecting)
            case .failed(let error):
                self.finish(.failed(error.localizedDescription))
            case .cancelled:
                self.finish(.cancelled)
            case .preparing, .setup:
                self.onPhase?(.connecting)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)

        // Give up reporting silence after a while and say what went wrong.
        queue.asyncAfter(deadline: .now() + Self.unreachableTimeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let arrived = self.reachedPeer
            let reason = self.lastWaitingReason
            self.lock.unlock()
            guard !arrived else { return }
            self.finish(.failed(Self.unreachableMessage(reason)))
            self.connection.cancel()
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):  return "\(code)"
        case .dns(let code):    return "DNS error \(code)"
        case .tls(let status):  return "TLS error \(status)"
        default:                return error.localizedDescription
        }
    }

    /// Local Network permission is by far the most common cause on macOS 15 and later,
    /// and it fails silently: the connection simply never completes.
    private static func unreachableMessage(_ reason: String?) -> String {
        // ECONNREFUSED means we reached the Mac and it refused: the address is right but
        // nothing is listening. That is a different problem from being unable to reach
        // it at all, and deserves different advice.
        if reason?.contains("ECONNREFUSED") == true || reason?.contains("61") == true {
            return "The other Mac refused the connection. Station may not be set to "
                 + "receive there, or this entry is left over from an earlier run. "
                 + "Make sure Station is running and receiving on the other Mac, then "
                 + "try again."
        }
        var message = "Could not reach the other Mac"
        if let reason { message += " (\(reason))" }
        message += ". Check that Station is running and set to receive there, that both "
        message += "Macs are on the same network, and that Station is allowed under "
        message += "System Settings > Privacy & Security > Local Network on this Mac."
        return message
    }

    public func cancel() {
        connection.cancel()
    }

    /// Tell the peer a person here authorised the pairing. Sent after confirming, so
    /// it travels on the now-open channel.
    public func announceApproval() {
        send(.pairingApproved, Data())
    }

    /// Open the channel. On the Mac that was asked this follows authentication; on the
    /// Mac that asked it follows word that the other side approved.
    public func confirmPairing() {
        lock.lock()
        confirmed = true
        let outbound = pendingOutbound
        let inbound = pendingInbound
        pendingOutbound.removeAll()
        pendingInbound.removeAll()
        lock.unlock()

        onPhase?(.ready)
        // Inbound first: the peer's `hello` has to be seen before we answer it, and
        // ordering the other way would answer a message we have not processed yet.
        for (type, payload) in inbound { onMessage?(type, payload) }
        // Outside the lock: send() takes it per frame, which keeps each seal paired
        // with its enqueue.
        for (type, payload) in outbound { send(type, payload) }
    }

    // MARK: - Sending

    public func send(_ type: MessageType, _ payload: Data) {
        // Sealing and enqueueing must happen together. Each frame's sequence number
        // lives in its nonce and the receiver requires them to arrive in order, so
        // taking a number under the lock and sending after releasing it lets two
        // threads seal in one order and reach the wire in another. The receiver then
        // reads a non-monotonic nonce, treats it as a replay, and drops the
        // connection. Station really does send from two threads at once: clipboard
        // transfers run on a main-thread timer while replies go out on the network
        // queue.
        lock.lock()
        defer { lock.unlock() }

        guard confirmed, let cipher = sendCipher else {
            // Never drop app messages that arrive mid-handshake; deliver them in order
            // once the channel opens.
            pendingOutbound.append((type, payload))
            return
        }
        guard let sealed = try? cipher.seal(Framing.frame(type, payload)) else { return }
        sendRaw(.encrypted, sealed)
    }

    public func send<T: Encodable>(_ type: MessageType, json value: T) throws {
        send(type, try JSONEncoder().encode(value))
    }

    private func sendRaw(_ type: MessageType, _ payload: Data) {
        // Its own lock, deliberately. `sendRaw` is called from `send` with `lock`
        // already held, and NSLock is not recursive: reusing it here deadlocks every
        // send instantly. Network.framework may also invoke the completion
        // synchronously, which would re-enter from the other direction.
        inFlightLock.lock()
        inFlight += 1
        inFlightLock.unlock()
        connection.send(content: Framing.frame(type, payload),
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.inFlightLock.lock()
            self.inFlight -= 1
            self.inFlightLock.unlock()
            if let error { self.onError?(error) }
        })
    }

    /// Frames handed to the transport that it has not finished writing.
    ///
    /// This is the only honest measure of whether the far end is keeping up. The
    /// receiving Mac injects each event synchronously before reading again, so a peer
    /// that cannot inject as fast as we send stops draining its socket, TCP backpressure
    /// reaches us, and these completions stop firing. Without watching it, Station will
    /// happily queue an unbounded backlog: the pointer over there falls seconds behind,
    /// which the user experiences not as lag but as the cursor having vanished.
    private var inFlight = 0
    private let inFlightLock = NSLock()

    /// Whether the far end is failing to keep up with what we are sending.
    public var isCongested: Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight > Self.congestionThreshold
    }

    /// Roughly a tenth of a second of pointer motion. High enough that ordinary
    /// scheduling jitter does not trip it, low enough that the backlog stays within
    /// what a person perceives as immediate.
    private static let congestionThreshold = 24

    // MARK: - Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let content, !content.isEmpty {
                self.lock.lock()
                self.decoder.append(content)
                var frames: [(MessageType, Data)] = []
                var thrown: Error?
                while true {
                    do {
                        guard let frame = try self.decoder.next() else { break }
                        frames.append(frame)
                    } catch {
                        thrown = error
                        if case FramingError.frameTooLarge = error { break }
                    }
                }
                self.lock.unlock()

                for frame in frames { self.handleFrame(frame.0, frame.1) }
                if let thrown {
                    self.onError?(thrown)
                    if case FramingError.frameTooLarge = thrown {
                        self.connection.cancel()
                        return
                    }
                }
            }

            if let error {
                self.finish(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    private func handleFrame(_ type: MessageType, _ payload: Data) {
        switch type {
        case .hsEphemeral:
            do {
                try handshake.receiveEphemeral(payload)
                if role == .responder {
                    sendRaw(.hsEphemeral, handshake.ephemeralMessage())
                }
                sendRaw(.hsIdentity, try handshake.identityMessage())
            } catch {
                fail(error)
            }

        case .hsIdentity:
            do {
                let result = try handshake.receiveIdentity(payload)
                lock.lock()
                outcome = result
                sendCipher = CipherState(key: result.sendKey)
                receiveCipher = CipherState(key: result.receiveKey)
                lock.unlock()

                onPeerIdentity?(result.peerIdentity, result.wasAlreadyKnown)
                if result.wasAlreadyKnown {
                    // Pinned identity already proves who this is; no user step needed.
                    confirmPairing()
                } else {
                    onPhase?(.awaitingConfirmation(sas: result.sas))
                }
            } catch {
                fail(error)
            }

        case .encrypted:
            lock.lock()
            let cipher = receiveCipher
            lock.unlock()
            guard let cipher else { return fail(HandshakeError.wrongState) }
            do {
                // Always decrypt, to keep the cipher's sequence counter in step.
                let inner = try cipher.open(payload)

                var innerDecoder = FrameDecoder()
                innerDecoder.append(inner)
                let frames = try innerDecoder.drainSkippingUnknown()
                    .map { ($0.type, $0.payload) }

                // Deliver nothing until the user has confirmed the SAS. Keys exist as
                // soon as the handshake completes, so without this an unconfirmed peer
                // could inject input before the user has checked the digits, which is
                // what the confirmation step exists to prevent. Messages are held, not
                // dropped, so nothing is lost when the peer confirms first.
                lock.lock()
                let mayDeliver = confirmed
                if !mayDeliver {
                    let room = Self.maxPendingInbound - pendingInbound.count
                    if room > 0 { pendingInbound.append(contentsOf: frames.prefix(room)) }
                }
                lock.unlock()

                // One exception to the gate: the peer telling us a person there
                // authorised the pairing. Everything else stays held, so an unapproved
                // peer still cannot deliver input.
                if !mayDeliver, frames.contains(where: { $0.0 == .pairingApproved }) {
                    onPeerApproved?()
                    return
                }
                guard mayDeliver else { return }

                for (type, payload) in frames { onMessage?(type, payload) }
            } catch {
                // A frame that fails authentication means tampering or desync; the
                // connection cannot be trusted to carry input after that.
                fail(error)
            }

        default:
            // Application messages must never arrive unencrypted.
            fail(HandshakeError.wrongState)
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        onPhase?(.failed(message))
        connection.cancel()
    }

    /// Report a terminal phase originating from the connection itself, once only.
    private func finish(_ phase: LinkPhase) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        onPhase?(phase)
    }
}

/// Accepts incoming peer connections and advertises over Bonjour.
public final class StationListener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue: DispatchQueue
    private let deviceName: String
    private let identity: Identity
    /// Look up a pinned identity for an incoming peer once it identifies itself.

    public var onLink: (@Sendable (StationLink) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public var onReady: (@Sendable (NWEndpoint.Port) -> Void)?

    public init(deviceName: String, identity: Identity,
                queue: DispatchQueue = .global(qos: .userInteractive)) {
        self.deviceName = deviceName
        self.identity = identity
        self.queue = queue
    }

    /// - Parameter port: defaults to `stationDefaultPort`, falling back to an ephemeral
    ///   port if it is already taken, so a second instance still runs.
    public func start(port: NWEndpoint.Port? = nil, advertise: Bool = true) throws {
        let requested = port ?? NWEndpoint.Port(rawValue: stationDefaultPort) ?? .any
        try startListener(on: requested, advertise: advertise, allowFallback: requested != .any)
    }

    private func startListener(on port: NWEndpoint.Port, advertise: Bool,
                               allowFallback: Bool) throws {
        let listener = try NWListener(using: TransportParameters.make(), on: port)

        if advertise {
            var txt = NWTXTRecord()
            txt["v"] = String(stationProtocolVersion)
            // The full public key, not a prefix. A Mac must be placeable in an
            // arrangement before it has ever been paired, and the arrangement refers to
            // Macs by identity, so that identity has to be knowable at discovery time.
            // It is a public key: publishing it reveals nothing.
            txt["id"] = identity.publicKeyData.map { String(format: "%02x", $0) }.joined()
            listener.service = NWListener.Service(name: deviceName,
                                                 type: stationBonjourType,
                                                 txtRecord: txt.data)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = StationLink(connection: connection, queue: self.queue,
                                   role: .responder, identity: self.identity,
                                   expectedPeerIdentity: nil)
            self.onLink?(link)
            link.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let bound = self.listener?.port, bound != .any { self.onReady?(bound) }
            case .failed(let error):
                // A busy fixed port only surfaces here, not when the listener is
                // constructed, so the fallback has to live in the failure path. Without
                // it a second Station on the same Mac, or a leftover process still
                // holding the port, simply never listens.
                if allowFallback, Self.isAddressInUse(error) {
                    self.listener?.cancel()
                    self.listener = nil
                    try? self.startListener(on: .any, advertise: advertise,
                                            allowFallback: false)
                } else {
                    self.onError?(error)
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    /// Whether Station's default port can be bound right now.
    ///
    /// Deliberately does not go through `start`, which falls back to an ephemeral port
    /// when the default is taken. That fallback lets tests bind freely, but it also
    /// means a caller asking "is another Station running here?" would always be told no.
    public static func defaultPortAvailable(timeout: TimeInterval = 1.5) -> Bool {
        guard let port = NWEndpoint.Port(rawValue: stationDefaultPort),
              let probe = try? NWListener(using: TransportParameters.make(), on: port) else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var available = false
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:  available = true;  semaphore.signal()
            case .failed: available = false; semaphore.signal()
            default:      break
            }
        }
        probe.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + timeout)
        probe.cancel()
        return available
    }

    /// The bound port, or nil until the listener is ready. `NWListener.port` reads back
    /// as zero rather than nil before binding, which would otherwise be dialled.
    public var port: NWEndpoint.Port? {
        guard let port = listener?.port, port != .any else { return nil }
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Finds Station peers on the local network.
///
/// Uses `NetServiceBrowser` with an explicit resolve rather than `NWBrowser`.
/// Measured directly: `NWBrowser` browse results carry no TXT record at all
/// (`metadata` is `.none`), while `NetService` resolution returns it reliably. Station
/// needs the TXT record, because that is where the peer advertises the pairing salt and
/// its protocol version, so browsing alone is not enough.
public final class PeerBrowser: NSObject, @unchecked Sendable {

    private let browser = NetServiceBrowser()
    /// Services must be retained while resolving or the resolve is abandoned.
    private var resolving: [NetService] = []
    /// Keyed by host and port rather than service name. Bonjour renames a re-registered
    /// service ("Mac (2)") while the dead record lingers, so keying by name would list
    /// the same Mac twice and invite the user to pick the stale one.
    private var found: [String: DiscoveredPeer] = [:]

    private static func key(host: String, port: UInt16) -> String { "\(host):\(port)" }
    private let lock = NSLock()

    public var onPeersChanged: (@Sendable ([DiscoveredPeer]) -> Void)?

    public override init() {
        super.init()
        browser.delegate = self
    }

    /// Must be called from a thread with a live run loop; the app's main thread is fine.
    public func start() {
        browser.searchForServices(ofType: stationBonjourType, inDomain: "local.")
    }

    public func stop() {
        browser.stop()
        lock.lock()
        resolving.removeAll()
        found.removeAll()
        lock.unlock()
        publish()
    }

    private func publish() {
        lock.lock()
        let peers = Array(found.values).sorted { $0.name < $1.name }
        lock.unlock()
        onPeersChanged?(peers)
    }
}

extension PeerBrowser: NetServiceBrowserDelegate, NetServiceDelegate {

    public func netServiceBrowser(_ browser: NetServiceBrowser,
                                  didFind service: NetService, moreComing: Bool) {
        lock.lock()
        resolving.append(service)
        lock.unlock()
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser,
                                  didRemove service: NetService, moreComing: Bool) {
        lock.lock()
        // The removed service may not have resolved, so match on name as well.
        found = found.filter { $0.value.name != service.name }
        resolving.removeAll { $0 === service }
        lock.unlock()
        if !moreComing { publish() }
    }

    /// The address to dial, chosen from the resolved sockaddrs rather than left to
    /// Network.framework.
    ///
    /// `service.hostName` is a UUID `.local.` name that mDNS resolves to several
    /// addresses at once: the peer's IPv4, a link-local IPv6 scoped to `en0`, and a
    /// unique-local IPv6 whose scope resolves to `<0>`. Dialling the *name* lets
    /// Network.framework pick, and with `includePeerToPeer` enabled it picked a
    /// peer-to-peer path over `ap1` that was down -- every dial failed instantly with
    /// ENETDOWN, for forty consecutive attempts over half an hour, while `nc` to the
    /// peer's IPv4 address on the same port succeeded every single time. Bonjour had
    /// resolved the service perfectly; the address it handed back was simply not one
    /// that could be reached, and nothing retried the others.
    ///
    /// Peer-to-peer stays enabled -- linking two Macs with no router between them is a
    /// feature -- but the address is ours to choose, so choose one known to route.
    private static func routableAddress(from service: NetService) -> String? {
        var fallback: String?
        for data in service.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self)
                else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(data.count), &buffer,
                                  socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
                else { return nil }
                return String(cString: buffer)
            }
            guard let host, !host.isEmpty else { continue }
            // A scoped address is only valid on the interface it names, and those are
            // precisely the ones that were failing.
            if host.hasPrefix("fe80") || host.contains("%") { continue }
            // IPv4 on the LAN is the one path known to work here; take it and stop.
            if !host.contains(":") { return host }
            if fallback == nil { fallback = host }
        }
        return fallback
    }

    public func netServiceDidResolveAddress(_ service: NetService) {
        let resolved = Self.routableAddress(from: service) ?? service.hostName
        guard let host = resolved, service.port > 0 else { return }
        let txt = service.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        func string(_ key: String) -> String? {
            txt[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        let peer = DiscoveredPeer(name: service.name,
                                  host: host,
                                  port: UInt16(service.port),
                                  deviceID: string("id"),
                                  protocolVersion: string("v").flatMap(Int.init))
        lock.lock()
        // Prefer the shortest name for a given endpoint: Bonjour's "(2)" suffix marks a
        // re-registration of the same Mac, not a different one.
        let key = Self.key(host: host, port: peer.port)
        if let existing = found[key], existing.name.count <= peer.name.count {
            found[key] = DiscoveredPeer(name: existing.name, host: peer.host, port: peer.port,
                                        deviceID: peer.deviceID,
                                        protocolVersion: peer.protocolVersion)
        } else {
            found[key] = peer
        }
        resolving.removeAll { $0 === service }
        lock.unlock()
        publish()
    }

    public func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.lock()
        resolving.removeAll { $0 === service }
        lock.unlock()
    }
}

public struct DiscoveredPeer: Sendable, Equatable, Identifiable {
    public let name: String
    public let host: String
    public let port: UInt16
    /// The peer's long-term identity, advertised so it can be arranged and recognised
    /// before ever being paired. A public key; publishing it reveals nothing.
    public let deviceID: DeviceID?
    public let protocolVersion: Int?

    /// Short form for display.
    public var shortFingerprint: String { String(deviceID?.prefix(8) ?? "") }
    public var id: String { name }

    public var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// True when this peer speaks a protocol version we understand.
    public var isCompatible: Bool { protocolVersion == stationProtocolVersion }

    /// True when we have everything needed to attempt a connection.
    public var isPairable: Bool { port > 0 && deviceID != nil }

    public init(name: String, host: String, port: UInt16,
                deviceID: DeviceID?, protocolVersion: Int?) {
        self.name = name
        self.host = host
        self.port = port
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
    }

    static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(byte)
            i = j
        }
        return bytes
    }
}
