import Foundation
import Network
import CoreGraphics
import StationKit

/// Owns a Station session: transport, capture, and injection.
///
/// Deliberately not `@MainActor`. Forwarded input must not queue behind the UI: a hop
/// to the main actor per event would add scheduling latency to every mouse move and
/// risk reordering a gesture stream. UI state is delivered separately through
/// `onEvent`, which callers are free to marshal wherever they like.
public final class SessionController: @unchecked Sendable {

    public enum Event: Sendable {
        /// The secondary is listening and discoverable.
        case listening(port: UInt16)
        /// First pairing with this peer: both Macs must show the same six digits and
        /// the user must confirm. This is a comparison, not a secret.
        case needsConfirmation(sas: String)
        /// Pairing completed and the peer's identity was pinned.
        case paired(peerName: String)
        case connected(peerName: String)
        case disconnected(reason: String?)
        /// Control moved to the peer (true) or came back (false).
        case controlMoved(remote: Bool)
        case armed
        case failed(String)
        /// Clipboard content moved between the Macs, with a direction and byte count.
        case clipboardSynced(sent: Bool, bytes: Int)
        case clipboardSkipped(String)
    }

    public var onEvent: (@Sendable (Event) -> Void)?

    private let deviceName: String
    private let deviceID: UUID
    private let identity: Identity
    private var listener: StationListener?
    /// Set while a first-time pairing is awaiting the user's SAS confirmation.
    private var pendingPeerIdentity: Data?
    private var pendingPeerName: String?
    private var pendingEdge: ScreenEdge?
    private var link: StationLink?
    private var capture: EventCapture?
    private let injection = EventInjection()
    private var peerID: DeviceID = ""
    private let clipboard = ClipboardMonitor()
    private var clipboardAssembler = ClipboardAssembler()
    private var clipboardTransferID: UInt64 = 0
    /// Off by default: sharing the clipboard is a meaningful privacy decision, not
    /// something to switch on silently the first time two Macs pair.
    public var clipboardSyncEnabled = false {
        didSet { clipboardSyncEnabled ? startClipboard() : clipboard.stop() }
    }

    public init(deviceName: String, deviceID: UUID = UUID(), identity: Identity? = nil) {
        self.deviceName = deviceName
        self.deviceID = deviceID
        // A missing identity is not recoverable, and generating a throwaway one would
        // silently break every existing pairing, so fall back only in-memory.
        self.identity = identity ?? ((try? PairingStore.loadOrCreateIdentity()) ?? .generate())
    }

    public var publicIdentity: Data { identity.publicKeyData }

    /// Hex of a public key, the form used to identify a Mac in an arrangement.
    public static func hex(_ data: Data) -> DeviceID {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public var localDeviceID: DeviceID { Self.hex(identity.publicKeyData) }

    // MARK: - Clipboard

    private func startClipboard() {
        clipboard.onSkipped = { [weak self] reason in
            self?.onEvent?(.clipboardSkipped(reason))
        }
        clipboard.onLocalChange = { [weak self] content in
            self?.sendClipboard(content)
        }
        // The timer needs the main run loop, and callers may enable this from anywhere.
        DispatchQueue.main.async { [weak self] in self?.clipboard.start() }
    }

    private func sendClipboard(_ content: ClipboardContent) {
        guard let link, let payload = try? content.encoded() else { return }
        clipboardTransferID &+= 1
        for chunk in ClipboardTransfer.chunks(of: payload, transferID: clipboardTransferID) {
            link.send(.clipboard, chunk)
        }
        onEvent?(.clipboardSynced(sent: true, bytes: payload.count))
    }

    private func receiveClipboard(_ frame: Data) {
        do {
            guard let payload = try clipboardAssembler.accept(frame) else { return }
            let content = try ClipboardContent.decode(payload)
            clipboard.apply(content)
            onEvent?(.clipboardSynced(sent: false, bytes: payload.count))
        } catch {
            onEvent?(.clipboardSkipped("could not read the clipboard from the other Mac"))
        }
    }

    /// Confirm the SAS matched on both Macs. Pins the peer so future connections need
    /// no user interaction.
    public func confirmPairing() {
        guard let link, let peerKey = pendingPeerIdentity else { return }
        PairingStore.upsert(PairingStore.Peer(publicKey: peerKey,
                                              name: pendingPeerName ?? "Mac",
                                              edge: pendingEdge ?? .right))
        pendingPeerIdentity = nil
        link.confirmPairing()
        onEvent?(.paired(peerName: pendingPeerName ?? "Mac"))
    }

    /// Ensure the tap is released and the cursor restored if the process is signalled.
    /// Without this, quitting while control is on a peer leaves the local mouse
    /// decoupled and the pointer hidden.
    public func installTerminationHandlers() {
        CursorControl.addTerminationCleanup { [weak self] in self?.stop() }
    }

    // MARK: - Secondary

    /// Listen for a primary and inject whatever it sends.
    public func startReceiving() {
        stop()
        let screens = ScreenGeometry.localScreens()

        let listener = StationListener(deviceName: deviceName, identity: identity,
                                       knownPeers: { PairingStore.knownPeerKeys() })
        listener.onError = { [weak self] error in
            self?.onEvent?(.failed(error.localizedDescription))
        }
        listener.onReady = { [weak self] port in
            self?.onEvent?(.listening(port: port.rawValue))
        }
        listener.onLink = { [weak self] link in
            guard let self else { return }
            self.link = link
            link.onPeerIdentity = { [weak self] key, known in
                self?.pendingPeerIdentity = known ? nil : key
                self?.pendingPeerName = PairingStore.peer(withKey: key)?.name
            }
            link.onPhase = { [weak self] phase in
                switch phase {
                case .awaitingConfirmation(let sas): self?.onEvent?(.needsConfirmation(sas: sas))
                case .failed(let reason):            self?.onEvent?(.disconnected(reason: reason))
                case .cancelled:                     self?.onEvent?(.disconnected(reason: nil))
                default: break
                }
            }
            link.onMessage = { [weak self] type, payload in
                self?.handleIncoming(type: type, payload: payload, link: link, screens: screens)
            }
            // Not started here: StationListener starts the link once handlers are set.
            // Starting it twice runs two concurrent receive loops on one connection,
            // which interleave reads and corrupt framing.
        }
        do {
            try listener.start()
            self.listener = listener
        } catch {
            onEvent?(.failed(error.localizedDescription))
        }
    }

    private func handleIncoming(type: MessageType, payload: Data,
                                link: StationLink, screens: ScreenSet) {
        switch type {
        case .hello:
            let name = (try? JSONDecoder().decode(Hello.self, from: payload))?.deviceName ?? "Mac"
            pendingPeerName = name
            onEvent?(.connected(peerName: name))
            // The primary needs our geometry to scale pointer motion correctly.
            try? link.send(.screens, json: screens)

        case .enterScreen:
            guard let msg = EnterScreen.decode(payload) else { return }
            injection.enter(at: NormalizedPoint(x: msg.normalizedX, y: msg.normalizedY))
            onEvent?(.controlMoved(remote: true))

        case .leaveScreen:
            injection.leave()
            onEvent?(.controlMoved(remote: false))

        case .input:
            guard let event = InputEvent.decode(payload) else { return }
            injection.inject(event)

        case .clipboard:
            receiveClipboard(payload)

        default:
            break
        }
    }

    // MARK: - Primary

    /// Connect to a peer and forward input when the pointer crosses `edge`.
    public func startSending(host: String, port: UInt16, edge: ScreenEdge,
                             expectedPeerIdentity: Data? = nil) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onEvent?(.failed("Invalid port \(port)"))
            return
        }
        startSending(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                     edge: edge, expectedPeerIdentity: expectedPeerIdentity)
    }

    /// Connect to a peer discovered over Bonjour.
    public func startSending(endpoint: NWEndpoint, edge: ScreenEdge,
                             expectedPeerIdentity: Data? = nil) {
        stop()
        pendingEdge = edge
        // Identify the peer by whatever identity it proves during the handshake; until
        // then, a placeholder that the capture layer keys its bounds against.
        peerID = expectedPeerIdentity.map(Self.hex) ?? "pending-peer"
        let capture = EventCapture(layout: Layout(placements: [edge: peerID]))
        self.capture = capture

        let link = StationLink(endpoint: endpoint, identity: identity,
                               expectedPeerIdentity: expectedPeerIdentity)
        self.link = link

        capture.onEvent = { [weak link] event in link?.send(.input, event.encode()) }
        capture.onEnterPeer = { [weak self, weak link] _, at in
            link?.send(.enterScreen, EnterScreen(normalizedX: at.x, normalizedY: at.y).encode())
            self?.onEvent?(.controlMoved(remote: true))
        }
        capture.onReturnLocal = { [weak self, weak link] _, _ in
            link?.send(.leaveScreen, Data())
            self?.onEvent?(.controlMoved(remote: false))
        }
        capture.onEscapeHatch = { [weak self, weak link] in
            link?.send(.leaveScreen, Data())
            self?.onEvent?(.controlMoved(remote: false))
        }

        link.onPeerIdentity = { [weak self] key, known in
            self?.pendingPeerIdentity = known ? nil : key
        }
        link.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .ready:
                try? link.send(.hello, json: Hello(deviceID: self.deviceID,
                                                   deviceName: self.deviceName,
                                                   role: .primary))
            case .awaitingConfirmation(let sas):
                self.onEvent?(.needsConfirmation(sas: sas))
            case .failed(let reason):
                self.onEvent?(.failed(reason))
                self.stop()
            case .cancelled:
                self.onEvent?(.disconnected(reason: nil))
            case .connecting, .handshaking:
                break
            }
        }
        link.onMessage = { [weak self] type, payload in
            guard let self else { return }
            if type == .clipboard {
                self.receiveClipboard(payload)
                return
            }
            guard type == .screens,
                  let peerScreens = try? JSONDecoder().decode(ScreenSet.self, from: payload) else { return }
            // The tap must be created on the thread running the run loop it attaches to.
            DispatchQueue.main.async {
                capture.setPeerBounds(peerScreens.bounds, for: self.peerID)
                do {
                    try capture.start()
                    self.onEvent?(.armed)
                } catch {
                    self.onEvent?(.failed(error.localizedDescription))
                }
            }
        }
        link.start()
    }

    public func stop() {
        clipboard.stop()
        // Tearing down the capture releases the cursor, so it must happen on the
        // run-loop thread and must happen even if the link is already gone.
        if let capture {
            if Thread.isMainThread {
                capture.stop()
            } else {
                DispatchQueue.main.sync { capture.stop() }
            }
        }
        capture = nil
        link?.cancel()
        link = nil
        listener?.stop()
        listener = nil
    }
}
