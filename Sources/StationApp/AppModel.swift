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
    /// The arrangement of Macs. Edges are derived from it rather than chosen directly,
    /// so the picker it replaces cannot disagree with the layout.
    var grid = ScreenLayoutGrid()
    var localDeviceID: DeviceID = ""
    /// Off unless the user asks for it: sharing a clipboard between machines is a
    /// privacy decision, not a sensible default.
    var clipboardSyncEnabled = false {
        didSet { session?.clipboardSyncEnabled = clipboardSyncEnabled }
    }
    var lastClipboardActivity: String?
    var loginItemState: LoginItem.State = .disabled
    /// The edge the current session actually uses, for status text.
    private(set) var lastUsedEdge: ScreenEdge = .right

    /// Six digits both Macs display during a first pairing. The user confirms they
    /// match; this is a comparison, never a secret.
    var confirmationCode: String?

    var connectedPeer: String?
    /// Shown while receiving so the connection can be tested directly with
    /// `stationctl connect` when discovery is the thing that is broken.
    var listeningPort: UInt16?
    var controlIsRemote = false
    var statusMessage = "Not running"
    var lastError: String?
    /// Recent session events, newest first. Not shown in the menu; kept because
    /// pairing can succeed while a later stage fails, and a debug window will want it.
    private(set) var recentEvents: [String] = []

    private var session: SessionController?
    private let browser = PeerBrowser()
    private let deviceName = Host.current().localizedName ?? "Mac"
    private let deviceID = AppModel.persistentDeviceID()

    private var permissionTimer: Timer?

    init() {
        browser.onPeersChanged = { [weak self] peers in
            // Deliberately unfiltered. Silently dropping peers that fail a check meant
            // an empty list with no explanation; the UI shows why one is unusable.
            Task { @MainActor in self?.peers = peers }
        }
        localDeviceID = SessionController.hex(
            ((try? PairingStore.loadOrCreateIdentity()) ?? .generate()).publicKeyData)
        loginItemState = LoginItem.state
        grid = LayoutStore.load()
        LayoutStore.ensureLocal(localDeviceID, name: deviceName, in: &grid)
        registerWithTCCIfNeeded()
        startPermissionPolling()
        // Browse continuously. Starting on menu open meant discovery had only a moment
        // to find and resolve peers before the user gave up looking at an empty list.
        browser.start()
    }

    /// Ask for both permissions at launch when they are missing.
    ///
    /// This is what puts Station in the System Settings lists. An app appears under
    /// Input Monitoring only once it has *called* the request API; merely preflighting
    /// does not register it. Waiting for the user to press a button in our own UI meant
    /// that a user who went straight to System Settings found no Station entry at all.
    ///
    /// macOS shows each prompt at most once per signature, so this is not repeated
    /// nagging: on later launches the calls are silent no-ops.
    private func registerWithTCCIfNeeded() {
        let current = Permissions.current()
        permissions = current
        guard !current.allGranted else { return }

        // Stagger the two requests. Firing both in the same turn of the run loop races
        // the two prompts against each other and one can be dropped, which leaves that
        // permission unregistered and absent from System Settings.
        if !current.inputMonitoring {
            Permissions.requestInputMonitoring()
        }
        if !current.accessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Permissions.requestAccessibility()
            }
        }
    }

    /// Some TCC changes are only picked up cleanly by a fresh process. Offered as a
    /// fallback so a user who has granted everything but still sees "not granted" has
    /// an obvious way forward rather than a dead end.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    /// Grants are made in System Settings, in another process, with no notification
    /// back to us. Poll so the UI updates on its own instead of needing "Check again".
    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let latest = Permissions.current()
                if latest != self.permissions { self.permissions = latest }
                // Login item state changes in System Settings, with no notification.
                let login = LoginItem.state
                if login != self.loginItemState { self.loginItemState = login }
            }
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

    // MARK: - Start at login

    var startsAtLogin: Bool { loginItemState == .enabled }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // Read back rather than assuming: macOS may leave it requiring approval.
        loginItemState = LoginItem.state
    }

    func openLoginItemsSettings() {
        LoginItem.openLoginItemsSettings()
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
        // An unplaced peer has no route to it. Default to the right rather than
        // refusing, then let the arrangement take over once the user places it.
        let resolvedEdge = edge(toward: peer) ?? .right
        let session = makeSession()
        self.session = session
        mode = .sending
        statusMessage = "Connecting to \(peer.name)…"
        // A previously pinned identity authenticates without any user interaction.
        let pinned = PairingStore.peers().first { $0.name == peer.name }?.publicKey
        lastUsedEdge = resolvedEdge
        session.startSending(endpoint: peer.endpoint, edge: resolvedEdge,
                             expectedPeerIdentity: pinned)
    }

    func stop() {
        session?.stop()
        session = nil
        mode = .idle
        connectedPeer = nil
        controlIsRemote = false
        confirmationCode = nil
        listeningPort = nil
        statusMessage = "Not running"
    }

    func stopDiscovery() { browser.stop() }

    // MARK: - Layout

    /// Paired Macs that have no place in the arrangement yet.
    var unplacedPeers: [ScreenLayoutGrid.Placement] {
        PairingStore.peers()
            .filter { grid.placement(of: $0.id) == nil }
            .map { ScreenLayoutGrid.Placement(id: $0.id,
                                              position: GridPosition(column: 0, row: 0),
                                              name: $0.name) }
    }

    func moveMac(_ id: DeviceID, to position: GridPosition) {
        let name = grid.placement(of: id)?.name
            ?? PairingStore.peers().first { $0.id == id }?.name
            ?? "Mac"
        grid.place(id, name: name, at: position)
        LayoutStore.save(grid)
    }

    func saveLayout() {
        LayoutStore.save(grid)
    }

    /// Which edge of this Mac leads to `peer`, from the arrangement. Nil when the two
    /// are not placed side by side, which is the honest answer: there is no route.
    func edge(toward peer: DiscoveredPeer) -> ScreenEdge? {
        guard let id = peerIdentity(for: peer) else { return nil }
        return grid.edge(from: localDeviceID, to: id)
    }

    private func peerIdentity(for peer: DiscoveredPeer) -> DeviceID? {
        // Prefer the advertised identity fingerprint; fall back to matching by name for
        // a peer that has been paired but is advertising an older record.
        if let fingerprint = peer.identityFingerprint,
           let match = PairingStore.peers().first(where: { $0.id.hasPrefix(fingerprint) }) {
            return match.id
        }
        return PairingStore.peers().first { $0.name == peer.name }?.id
    }

    /// Bring the confirmation in front of the user rather than hiding it in a menu.
    private func presentConfirmation(_ sas: String) {
        let alert = NSAlert()
        alert.messageText = "Pair with the other Mac?"
        alert.informativeText = """
            Both Macs should be showing these digits:

                    \(sas)

            Confirm this on BOTH Macs to finish pairing. If the digits differ,             someone may be intercepting the connection — do not pair.
            """
        alert.addButton(withTitle: "They match — pair")
        alert.addButton(withTitle: "They differ")
        alert.alertStyle = .informational

        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            confirmPairing()
        } else {
            rejectPairing()
        }
    }

    /// The user has checked the six digits match on both Macs.
    func confirmPairing() {
        session?.confirmPairing()
        confirmationCode = nil
        // Confirming locally is only half of it. Input cannot flow until the other Mac
        // confirms too, so do not imply the pairing is finished.
        statusMessage = "Waiting for the other Mac to confirm…"
    }

    /// The digits did not match, which means something is interposed. Tear down.
    func rejectPairing() {
        lastError = "The codes did not match. Someone may be intercepting the connection."
        stop()
    }

    /// Why a discovered peer cannot be used, or nil if it is usable.
    func unusableReason(for peer: DiscoveredPeer) -> String? {
        if !peer.isCompatible {
            return peer.protocolVersion == nil
                ? "Could not read pairing details"
                : "Different Station version"
        }
        if !peer.isPairable { return "Not ready to pair" }
        return nil
    }

    private func makeSession() -> SessionController {
        let session = SessionController(deviceName: deviceName, deviceID: deviceID)
        // Quitting while control is on a peer must not leave the mouse decoupled.
        session.installTerminationHandlers()
        session.clipboardSyncEnabled = clipboardSyncEnabled
        session.onEvent = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        return session
    }

    private func record(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        recentEvents.insert("\(stamp)  \(text)", at: 0)
        if recentEvents.count > 12 { recentEvents.removeLast() }
    }

    private func apply(_ event: SessionController.Event) {
        record(Self.describe(event))
        switch event {
        case .listening(let port):
            listeningPort = port
            statusMessage = "Waiting for a Mac to connect"
        case .needsConfirmation(let sas):
            confirmationCode = sas
            statusMessage = "Confirm the code matches"
            // Both Macs must confirm, and the menu bar popover only renders while it is
            // open, so a user who never opens it never sees the prompt. The pairing then
            // stalls with one side reporting success and the other silently waiting.
            presentConfirmation(sas)
        case .paired(let peerName):
            confirmationCode = nil
            statusMessage = "Paired with \(peerName)"
        case .connected(let peerName):
            connectedPeer = peerName
            statusMessage = "Connected to \(peerName)"
        case .disconnected(let reason):
            connectedPeer = nil
            controlIsRemote = false
            statusMessage = reason.map { "Disconnected: \($0)" } ?? "Disconnected"
        case .controlMoved(let remote):
            controlIsRemote = remote
            statusMessage = remote ? "Control is on the other Mac" : "Control is here"
        case .armed:
            statusMessage = "Ready — move the pointer off the \(lastUsedEdge.rawValue) edge"
        case .clipboardSynced(let sent, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            lastClipboardActivity = sent ? "Clipboard sent (\(size))" : "Clipboard received (\(size))"
        case .clipboardSkipped(let reason):
            lastClipboardActivity = reason
        case .failed(let message):
            lastError = message
            statusMessage = "Failed"
            mode = .idle
        }
    }

    private static func describe(_ event: SessionController.Event) -> String {
        switch event {
        case .listening(let port):        return "listening on \(port)"
        case .needsConfirmation:          return "awaiting code confirmation"
        case .paired(let name):           return "paired with \(name)"
        case .connected(let name):        return "connected to \(name)"
        case .disconnected(let reason):   return "disconnected\(reason.map { ": \($0)" } ?? "")"
        case .controlMoved(let remote):   return remote ? "control -> peer" : "control -> here"
        case .armed:                      return "capture armed"
        case .failed(let message):        return "FAILED: \(message)"
        case .clipboardSynced(let sent, let bytes):
            return "clipboard \(sent ? "sent" : "received") \(bytes)B"
        case .clipboardSkipped(let reason): return "clipboard skipped: \(reason)"
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
