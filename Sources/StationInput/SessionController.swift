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
        /// The secondary is listening; show this pairing material to the user.
        case listening(code: String, salt: Data, port: UInt16)
        case connected(peerName: String)
        case disconnected(reason: String?)
        /// Control moved to the peer (true) or came back (false).
        case controlMoved(remote: Bool)
        case armed
        case failed(String)
    }

    public var onEvent: (@Sendable (Event) -> Void)?

    private let deviceName: String
    private let deviceID: UUID
    private var listener: StationListener?
    private var link: StationLink?
    private var capture: EventCapture?
    private let injection = EventInjection()
    private var peerID = UUID()

    public init(deviceName: String, deviceID: UUID = UUID()) {
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    /// Ensure the tap is released and the cursor restored if the process is signalled.
    /// Without this, quitting while control is on a peer leaves the local mouse
    /// decoupled and the pointer hidden.
    public func installTerminationHandlers() {
        CursorControl.addTerminationCleanup { [weak self] in self?.stop() }
    }

    // MARK: - Secondary

    /// Listen for a primary and inject whatever it sends.
    public func startReceiving(code: String? = nil) {
        stop()
        let pairingCode = code ?? Pairing.generateCode()
        let salt = Pairing.generateSalt()
        let screens = ScreenGeometry.localScreens()

        let listener = StationListener(deviceName: deviceName)
        listener.onError = { [weak self] error in
            self?.onEvent?(.failed(error.localizedDescription))
        }
        listener.onReady = { [weak self] port in
            self?.onEvent?(.listening(code: pairingCode, salt: salt, port: port.rawValue))
        }
        listener.onLink = { [weak self] link in
            guard let self else { return }
            self.link = link
            link.onStateChange = { [weak self] state in
                switch state {
                case .failed(let reason): self?.onEvent?(.disconnected(reason: reason))
                case .cancelled:          self?.onEvent?(.disconnected(reason: nil))
                default: break
                }
            }
            link.onMessage = { [weak self] type, payload in
                self?.handleIncoming(type: type, payload: payload, link: link, screens: screens)
            }
        }
        do {
            try listener.start(credential: .code(pairingCode), salt: salt)
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

        default:
            break
        }
    }

    // MARK: - Primary

    /// Connect to a peer and forward input when the pointer crosses `edge`.
    public func startSending(host: String, port: UInt16, code: String, salt: Data, edge: ScreenEdge) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onEvent?(.failed("Invalid port \(port)"))
            return
        }
        startSending(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                     code: code, salt: salt, edge: edge)
    }

    /// Connect to a peer discovered over Bonjour.
    public func startSending(endpoint: NWEndpoint, code: String, salt: Data, edge: ScreenEdge) {
        stop()
        peerID = UUID()
        let capture = EventCapture(layout: Layout(placements: [edge: peerID]))
        self.capture = capture

        let link = StationLink(endpoint: endpoint, credential: .code(code), salt: salt)
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

        link.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                try? link.send(.hello, json: Hello(deviceID: self.deviceID,
                                                   deviceName: self.deviceName,
                                                   role: .primary))
            case .failed(let reason):
                self.onEvent?(.failed(reason))
                self.stop()
            case .cancelled:
                self.onEvent?(.disconnected(reason: nil))
            case .connecting:
                break
            }
        }
        link.onMessage = { [weak self] type, payload in
            guard let self, type == .screens,
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
