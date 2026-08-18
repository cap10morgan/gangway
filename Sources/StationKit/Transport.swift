import Foundation
import Network

public let stationBonjourType = "_station._tcp"

/// Builds the Network.framework parameter stack shared by both ends.
enum TransportParameters {
    /// The TLS-PSK identity is the server's lookup key for the pre-shared key, so it
    /// must be byte-identical on both ends; a per-device value fails the handshake
    /// with `-9864 unknown PSK identity`. It is not secret and carries no peer
    /// information. Peers identify themselves in `Hello`, after the channel is
    /// encrypted, which is the correct layer for it.
    static let pskIdentity = Data("station-psk-v1".utf8)

    static func make(psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = pskIdentity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t.AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        // Input forwarding is a latency game, not a throughput game. Nagle would
        // coalesce our tiny event frames and add up to 40ms of visible cursor lag.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 1
        // Drop a wedged peer quickly so the primary can release the cursor.
        tcp.connectionTimeout = 5

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice   // prioritize on congested Wi-Fi
        return params
    }
}

public enum LinkState: Sendable, Equatable {
    case connecting
    case ready
    case failed(String)
    case cancelled
}

/// A framed, authenticated, encrypted connection to one peer.
///
/// Not an actor: `NWConnection` already serializes onto the queue we hand it, and the
/// send path is on the input hot path where actor hops would add avoidable latency.
public final class StationLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var decoder = FrameDecoder()
    private let lock = NSLock()

    public var onMessage: (@Sendable (MessageType, Data) -> Void)?
    public var onStateChange: (@Sendable (LinkState) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public var endpointDescription: String { String(describing: connection.endpoint) }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Dial a discovered peer.
    public convenience init(endpoint: NWEndpoint, credential: PairingCredential, salt: Data,
                            queue: DispatchQueue = .global(qos: .userInteractive)) {
        let params = TransportParameters.make(psk: credential.psk(salt: salt))
        self.init(connection: NWConnection(to: endpoint, using: params), queue: queue)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
                self.receiveLoop()
            case .waiting(let error):
                self.onError?(error)
                // Network.framework parks a failed TLS handshake in `.waiting` and
                // retries indefinitely. A wrong pairing code is never going to start
                // working, so surface it immediately instead of spinning forever.
                // Transport-level problems (no route, refused) stay retryable.
                if case .tls(let status) = error {
                    self.onStateChange?(.failed(Self.describeTLS(status)))
                    self.connection.cancel()
                } else {
                    self.onStateChange?(.connecting)
                }
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.cancelled)
            case .preparing, .setup:
                self.onStateChange?(.connecting)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    public func send(_ type: MessageType, _ payload: Data) {
        connection.send(content: Framing.frame(type, payload),
                        completion: .contentProcessed { [weak self] error in
            if let error { self?.onError?(error) }
        })
    }

    public func send<T: Encodable>(_ type: MessageType, json value: T) throws {
        send(type, try JSONEncoder().encode(value))
    }

    /// Map the TLS status codes a user can actually cause to plain language.
    static func describeTLS(_ status: OSStatus) -> String {
        switch status {
        case -9820, -9846: return "Incorrect pairing code"
        case -9864:        return "Pairing key mismatch"
        default:           return "Secure connection failed (\(status))"
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let content, !content.isEmpty {
                self.lock.lock()
                self.decoder.append(content)
                var drained: [(MessageType, Data)] = []
                var thrown: Error?
                while true {
                    do {
                        guard let frame = try self.decoder.next() else { break }
                        drained.append(frame)
                    } catch {
                        // An unknown message type is skipped by the decoder, so keep
                        // draining; a size violation is fatal and ends the loop.
                        thrown = error
                        if case FramingError.frameTooLarge = error { break }
                    }
                }
                self.lock.unlock()

                for (type, payload) in drained { self.onMessage?(type, payload) }
                if let thrown {
                    self.onError?(thrown)
                    if case FramingError.frameTooLarge = thrown {
                        self.connection.cancel()
                        return
                    }
                }
            }

            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }
}

/// Accepts incoming peer connections and advertises over Bonjour.
public final class StationListener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue: DispatchQueue
    private let deviceName: String

    public var onLink: (@Sendable (StationLink) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?
    /// Fires once the listener is actually bound and accepting connections.
    public var onReady: (@Sendable (NWEndpoint.Port) -> Void)?

    public init(deviceName: String, queue: DispatchQueue = .global(qos: .userInteractive)) {
        self.deviceName = deviceName
        self.queue = queue
    }

    /// - Parameter credential: what an incoming peer must prove it knows. While the
    ///   user has a pairing code on screen this is `.code`; otherwise `.longTerm`.
    /// - Parameter salt: also published in the Bonjour TXT record. The salt cannot
    ///   travel inside the encrypted channel because it is needed to derive the key
    ///   that establishes it, so it is public by design. Publishing it means the user
    ///   only ever types the six-digit code.
    public func start(credential: PairingCredential, salt: Data, port: NWEndpoint.Port? = nil,
                      advertise: Bool = true) throws {
        let params = TransportParameters.make(psk: credential.psk(salt: salt))
        let listener = try NWListener(using: params, on: port ?? .any)
        if advertise {
            var txt = NWTXTRecord()
            txt["salt"] = salt.map { String(format: "%02x", $0) }.joined()
            txt["v"] = String(stationProtocolVersion)
            listener.service = NWListener.Service(name: deviceName,
                                                 type: stationBonjourType,
                                                 txtRecord: txt.data)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = StationLink(connection: connection, queue: self.queue)
            self.onLink?(link)
            link.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // `NWListener.port` is non-nil but zero until the listener actually
                // binds, so callers must not read it before this point or they will
                // dial port 0 and get EADDRNOTAVAIL.
                if let port = self?.listener?.port, port != .any {
                    self?.onReady?(port)
                }
            case .failed(let error):
                self?.onError?(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// The bound port, or nil until the listener is ready. Zero is treated as
    /// "not yet bound" rather than reported as a usable port.
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
public final class PeerBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue: DispatchQueue

    public var onPeersChanged: (@Sendable ([DiscoveredPeer]) -> Void)?

    public init(queue: DispatchQueue = .global(qos: .utility)) {
        self.queue = queue
    }

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: stationBonjourType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { DiscoveredPeer(result: $0) }
            self?.onPeersChanged?(peers)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

public struct DiscoveredPeer: Sendable, Equatable, Identifiable {
    public let name: String
    public let endpoint: NWEndpoint
    /// Pairing salt advertised by the peer, if it published one.
    public let salt: Data?
    public let protocolVersion: Int?
    public var id: String { name }

    /// True when this peer speaks a protocol version we understand.
    public var isCompatible: Bool {
        guard let protocolVersion else { return false }
        return protocolVersion == stationProtocolVersion
    }

    init?(result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        self.name = name
        self.endpoint = result.endpoint

        if case .bonjour(let txt) = result.metadata {
            self.salt = txt["salt"].flatMap(Self.hexToData)
            self.protocolVersion = txt["v"].flatMap(Int.init)
        } else {
            self.salt = nil
            self.protocolVersion = nil
        }
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
