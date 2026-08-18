import Foundation
import Network

public let stationBonjourType = "_station._tcp"

/// Builds the Network.framework parameter stack shared by both ends.
///
/// Plain TCP: confidentiality and authentication come from `SecureChannel`, not TLS.
/// The previous TLS-PSK arrangement required a shared secret before the connection
/// existed, which forced a low-entropy typed code and an offline-guessable handshake.
enum TransportParameters {
    static func make() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Input forwarding is a latency game, not a throughput game. Nagle would
        // coalesce our tiny event frames and add up to 40ms of visible cursor lag.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 1
        tcp.connectionTimeout = 5

        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice   // prioritize on congested Wi-Fi
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
    /// App messages queued while the handshake or user confirmation is outstanding.
    private var pendingOutbound: [(MessageType, Data)] = []

    public var onMessage: (@Sendable (MessageType, Data) -> Void)?
    public var onPhase: (@Sendable (LinkPhase) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    /// Peer's long-term public key and whether it matched a pinned one.
    public var onPeerIdentity: (@Sendable (Data, Bool) -> Void)?

    public var endpointDescription: String { String(describing: connection.endpoint) }

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
                self.onPhase?(.handshaking)
                self.receiveLoop()
                // The initiator opens the handshake; the responder answers.
                if self.role == .initiator {
                    self.sendRaw(.hsEphemeral, self.handshake.ephemeralMessage())
                }
            case .waiting(let error):
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
    }

    public func cancel() {
        connection.cancel()
    }

    /// Call once the user has confirmed the SAS matches on both Macs.
    public func confirmPairing() {
        lock.lock()
        confirmed = true
        let queued = pendingOutbound
        pendingOutbound.removeAll()
        lock.unlock()
        onPhase?(.ready)
        for (type, payload) in queued { send(type, payload) }
    }

    // MARK: - Sending

    public func send(_ type: MessageType, _ payload: Data) {
        lock.lock()
        let ready = confirmed && sendCipher != nil
        if !ready {
            // Never drop app messages that arrive mid-handshake; deliver them in order
            // once the channel opens.
            pendingOutbound.append((type, payload))
            lock.unlock()
            return
        }
        let cipher = sendCipher!
        lock.unlock()

        guard let sealed = try? cipher.seal(Framing.frame(type, payload)) else { return }
        sendRaw(.encrypted, sealed)
    }

    public func send<T: Encodable>(_ type: MessageType, json value: T) throws {
        send(type, try JSONEncoder().encode(value))
    }

    private func sendRaw(_ type: MessageType, _ payload: Data) {
        connection.send(content: Framing.frame(type, payload),
                        completion: .contentProcessed { [weak self] error in
            if let error { self?.onError?(error) }
        })
    }

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

                // But deliver nothing until the user has confirmed the SAS. The keys
                // exist as soon as the handshake completes, so without this an
                // unconfirmed peer could inject input before the user has had any
                // chance to check the digits, which is exactly what the confirmation
                // step is there to prevent.
                lock.lock()
                let mayDeliver = confirmed
                lock.unlock()
                guard mayDeliver else { return }

                var innerDecoder = FrameDecoder()
                innerDecoder.append(inner)
                while let frame = try innerDecoder.next() {
                    onMessage?(frame.type, frame.payload)
                }
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
    private let knownPeers: @Sendable () -> [Data]

    public var onLink: (@Sendable (StationLink) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    public var onReady: (@Sendable (NWEndpoint.Port) -> Void)?

    public init(deviceName: String, identity: Identity,
                knownPeers: @escaping @Sendable () -> [Data] = { [] },
                queue: DispatchQueue = .global(qos: .userInteractive)) {
        self.deviceName = deviceName
        self.identity = identity
        self.knownPeers = knownPeers
        self.queue = queue
    }

    public func start(port: NWEndpoint.Port? = nil, advertise: Bool = true) throws {
        let listener = try NWListener(using: TransportParameters.make(), on: port ?? .any)

        if advertise {
            var txt = NWTXTRecord()
            txt["v"] = String(stationProtocolVersion)
            // The identity fingerprint lets a primary tell a re-paired Mac from a new
            // one before connecting. It is a public key hash, not a secret.
            txt["id"] = identity.publicKeyData.prefix(8)
                .map { String(format: "%02x", $0) }.joined()
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
            switch state {
            case .ready:
                if let port = self?.listener?.port, port != .any { self?.onReady?(port) }
            case .failed(let error):
                self?.onError?(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
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
    private var found: [String: DiscoveredPeer] = [:]
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
        found.removeValue(forKey: service.name)
        resolving.removeAll { $0 === service }
        lock.unlock()
        if !moreComing { publish() }
    }

    public func netServiceDidResolveAddress(_ service: NetService) {
        guard let host = service.hostName, service.port > 0 else { return }
        let txt = service.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        func string(_ key: String) -> String? {
            txt[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        let peer = DiscoveredPeer(name: service.name,
                                  host: host,
                                  port: UInt16(service.port),
                                  identityFingerprint: string("id"),
                                  protocolVersion: string("v").flatMap(Int.init))
        lock.lock()
        found[service.name] = peer
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
    /// Short hash of the peer's long-term public key, advertised so a primary can tell
    /// a re-installed Mac from a new one before connecting. Not a secret.
    public let identityFingerprint: String?
    public let protocolVersion: Int?
    public var id: String { name }

    public var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// True when this peer speaks a protocol version we understand.
    public var isCompatible: Bool { protocolVersion == stationProtocolVersion }

    /// True when we have everything needed to attempt a connection.
    public var isPairable: Bool { port > 0 }

    public init(name: String, host: String, port: UInt16,
                identityFingerprint: String?, protocolVersion: Int?) {
        self.name = name
        self.host = host
        self.port = port
        self.identityFingerprint = identityFingerprint
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
