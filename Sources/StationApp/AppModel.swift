import Foundation
import SwiftUI
import Network
import StationKit
import StationInput

/// UI-facing state. The session itself runs off the main actor so forwarded input
/// never queues behind the interface; this type only mirrors what the user sees.
@MainActor
@Observable
final class AppModel {

    enum Mode: Equatable {
        case idle
        case receiving          // this Mac is controlled by another
        case sending            // this Mac controls another
    }

    var mode: Mode = .idle
    var permissions = Permissions.current()
    var peers: [DiscoveredPeer] = []
    var edge: ScreenEdge = .right

    /// Shown while waiting to be paired, so the user can read it off the screen.
    var pairingCode: String?
    /// Code the user types when connecting to a peer.
    var enteredCode = ""

    var connectedPeer: String?
    var controlIsRemote = false
    var statusMessage = "Not running"
    var lastError: String?

    private var session: SessionController?
    private let browser = PeerBrowser()
    private let deviceName = Host.current().localizedName ?? "Mac"
    private let deviceID = AppModel.persistentDeviceID()

    init() {
        browser.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.peers = peers.filter { $0.isCompatible } }
        }
    }

    /// A stable identity across launches, so re-pairing is not required every restart.
    private static func persistentDeviceID() -> UUID {
        let key = "com.station.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: existing) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    func refreshPermissions() {
        permissions = Permissions.current()
    }

    // MARK: - Lifecycle

    func startReceiving() {
        guard permissions.allGranted else {
            lastError = "Grant Accessibility and Input Monitoring first."
            return
        }
        let session = makeSession()
        self.session = session
        mode = .receiving
        statusMessage = "Starting…"
        session.startReceiving()
    }

    func startSending(to peer: DiscoveredPeer) {
        guard permissions.allGranted else {
            lastError = "Grant Accessibility and Input Monitoring first."
            return
        }
        guard let salt = peer.salt else {
            lastError = "\(peer.name) is not advertising pairing information."
            return
        }
        guard enteredCode.count == Pairing.codeDigits else {
            lastError = "Enter the \(Pairing.codeDigits)-digit code shown on \(peer.name)."
            return
        }
        let session = makeSession()
        self.session = session
        mode = .sending
        statusMessage = "Connecting to \(peer.name)…"
        session.startSending(endpoint: peer.endpoint, code: enteredCode, salt: salt, edge: edge)
    }

    func stop() {
        session?.stop()
        session = nil
        mode = .idle
        connectedPeer = nil
        controlIsRemote = false
        pairingCode = nil
        statusMessage = "Not running"
    }

    func startDiscovery() { browser.start() }
    func stopDiscovery() { browser.stop() }

    private func makeSession() -> SessionController {
        let session = SessionController(deviceName: deviceName, deviceID: deviceID)
        // Quitting while control is on a peer must not leave the mouse decoupled.
        session.installTerminationHandlers()
        session.onEvent = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        return session
    }

    private func apply(_ event: SessionController.Event) {
        switch event {
        case .listening(let code, _, _):
            pairingCode = code
            statusMessage = "Waiting for a Mac to connect"
        case .connected(let peerName):
            connectedPeer = peerName
            pairingCode = nil
            statusMessage = "Connected to \(peerName)"
        case .disconnected(let reason):
            connectedPeer = nil
            controlIsRemote = false
            statusMessage = reason.map { "Disconnected: \($0)" } ?? "Disconnected"
        case .controlMoved(let remote):
            controlIsRemote = remote
            statusMessage = remote ? "Control is on the other Mac" : "Control is here"
        case .armed:
            statusMessage = "Ready — move the pointer off the \(edge.rawValue) edge"
        case .failed(let message):
            lastError = message
            statusMessage = "Failed"
            mode = .idle
        }
    }

    /// Icon reflects whether input is currently leaving this Mac.
    var menuBarSymbol: String {
        switch mode {
        case .idle:      return "rectangle.on.rectangle.slash"
        case .receiving: return controlIsRemote ? "dot.radiowaves.left.and.right" : "rectangle.on.rectangle"
        case .sending:   return controlIsRemote ? "arrow.right.to.line" : "rectangle.on.rectangle"
        }
    }
}
