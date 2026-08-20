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

    /// No controller/controlled split: Station is either part of the mesh or not.
    /// Which Mac is forwarding follows the pointer, and changes as it moves.
    private(set) var isRunning = false

    /// Whether the user wants Station active. Station runs by default and starts
    /// itself: there is nothing for the user to configure before it is useful, so a
    /// Start button was just a step between launching the app and it working. Turning
    /// it off is remembered, so an explicit choice is not undone on the next launch.
    /// Stored rather than computed straight from UserDefaults: `@Observable` tracks
    /// stored properties, so a computed one backed by defaults would not reliably
    /// refresh the view that toggles it.
    private static let enabledKey = "com.station.enabled"
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }
    var permissions = Permissions.current()
    var peers: [DiscoveredPeer] = []
    /// The arrangement of Macs. Edges are derived from it rather than chosen directly,
    /// so the picker it replaces cannot disagree with the layout.
    var grid = ScreenLayoutGrid()
    var localDeviceID: DeviceID = ""
    /// Off unless the user asks for it: sharing a clipboard between machines is a
    /// privacy decision, not a sensible default. Remembered once chosen, either way.
    var clipboardSyncEnabled = false {
        didSet {
            guard clipboardSyncEnabled != oldValue else { return }
            UserDefaults.standard.set(clipboardSyncEnabled, forKey: Self.clipboardKey)
            session?.clipboardSyncEnabled = clipboardSyncEnabled
        }
    }
    private static let clipboardKey = "com.station.clipboardSync"
    var lastClipboardActivity: String?
    var loginItemState: LoginItem.State = .disabled
    /// The edge the current session actually uses, for status text.
    private(set) var lastUsedEdge: ScreenEdge = .right

    /// A Mac asking to join, awaiting authentication here.
    var pendingApproval: (peer: DeviceID, name: String, code: String)?
    /// Shown passively while another Mac decides about us.
    var awaitingApproval: (name: String, code: String)?

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
    private let codePanel = PairingCodePanel()
    private let browser = PeerBrowser()
    private let deviceName = Host.current().localizedName ?? "Mac"

    private var permissionTimer: Timer?

    init() {
        browser.onPeersChanged = { [weak self] peers in
            // Deliberately unfiltered. Silently dropping peers that fail a check meant
            // an empty list with no explanation; the UI shows why one is unusable.
            Task { @MainActor in
                guard let self else { return }
                // Bonjour reports the service this Mac publishes, so drop ourselves.
                // Matching on identity rather than name, because two Macs can share a
                // name and Bonjour renames rather than deduplicating.
                let others = peers.filter { $0.deviceID != self.localDeviceID }
                self.peers = others
                self.session?.updateDiscovered(others)
                self.reconcilePlacementNames()
            }
        }
        // didSet does not run during init, so restore both directly.
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        clipboardSyncEnabled = UserDefaults.standard.bool(forKey: Self.clipboardKey)
        localDeviceID = SessionController.hex(
            ((try? PairingStore.loadOrCreateIdentity()) ?? .generate()).publicKeyData)
        loginItemState = LoginItem.state
        grid = LayoutStore.load()
        LayoutStore.ensureLocal(localDeviceID, name: deviceName, in: &grid)
        registerWithTCCIfNeeded()
        startPermissionPolling()
        // Start as soon as we can. Permissions may not be granted yet on a first run,
        // in which case the poller starts us the moment they are.
        startIfPossible()
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

    /// Poll for changes made in System Settings, which arrive with no notification.
    ///
    /// The queries run on a background queue and only the results touch the main actor.
    /// They are not cheap — TCC preflights, an SMAppService lookup and a preferences
    /// read that hits disk — and the event tap runs on the main run loop, so doing them
    /// there stalled forwarded input every time the timer fired. That showed up as the
    /// pointer and keystrokes going janky.
    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Never poll while input is being forwarded. Nothing here changes
                // during a control session, and latency matters more than freshness.
                guard !self.controlIsRemote else { return }
                let snapshot = await Self.readSystemState()
                self.applySystemState(snapshot)
            }
        }
    }

    private struct SystemState: Equatable {
        var permissions: Permissions
        var loginItem: LoginItem.State
    }

    private static func readSystemState() async -> SystemState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: SystemState(
                    permissions: Permissions.current(),
                    loginItem: LoginItem.state))
            }
        }
    }

    private func applySystemState(_ state: SystemState) {
        if state.permissions != permissions {
            permissions = state.permissions
            // Granting the last permission should just make Station work, rather than
            // leaving it idle behind a button.
            startIfPossible()
        }
        if state.loginItem != loginItemState { loginItemState = state.loginItem }
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

    /// Only ever "possible", never "happening": which edge a Universal Control device
    /// occupies is not discoverable, so this is shown as advice where edges are chosen.
    var universalControlEdgesEnabled: Bool {
        SystemConflicts.universalControlEdgesEnabled
    }

    func openDisplaysSettings() {
        SystemConflicts.openDisplaysSettings()
    }

    // MARK: - Lifecycle

    /// Start if the user has not turned Station off and the permissions allow it.
    func startIfPossible() {
        guard !isRunning, isEnabled, permissions.allGranted else { return }
        start()
    }

    func start() {
        guard permissions.allGranted else {
            lastError = "Grant Accessibility and Input Monitoring first."
            return
        }
        guard !isRunning else { return }
        let session = makeSession()
        self.session = session
        isRunning = true
        statusMessage = "Starting…"
        LayoutStore.ensureLocal(localDeviceID, name: deviceName, in: &grid)
        session.start(grid: grid)
    }

    func approvePending() async {
        guard let pending = pendingApproval else { return }
        // The code must be in the authentication reason itself. It is the only thing
        // that distinguishes the real Mac from something interposed, and a prompt that
        // merely says "allow X" invites approving without looking.
        // LAContext renders the reason as plain text with no styling available, so the
        // code is set apart with blank lines and wide digit spacing. It is the only
        // thing distinguishing the real Mac from something interposed, so it has to be
        // the most legible part of the prompt.
        let spaced = pending.code.map(String.init).joined(separator: "  ")
        let result = await Authorization.confirm(
            reason: """
                allow \(pending.name) to control this Mac.


                \(spaced)


                Approve only if \(pending.name) is showing this same code.
                """)
        switch result {
        case .authorized:
            session?.approve(peer: pending.peer)
            pendingApproval = nil
        case .declined:
            session?.decline(peer: pending.peer)
            pendingApproval = nil
        case .unavailable(let reason):
            lastError = reason
        }
    }

    func declinePending() {
        guard let pending = pendingApproval else { return }
        session?.decline(peer: pending.peer)
        pendingApproval = nil
    }

    func stop() {
        session?.stop()
        session = nil
        isRunning = false
        connectedPeer = nil
        controlIsRemote = false
        pendingApproval = nil
        awaitingApproval = nil
        codePanel.hide()
        listeningPort = nil
        statusMessage = "Not running"
    }

    func stopDiscovery() { browser.stop() }

    // MARK: - Layout

    /// Paired Macs that have no place in the arrangement yet.
    var unplacedPeers: [ScreenLayoutGrid.Placement] {
        // Discovered Macs, not only paired ones: a Mac must be placed before the
        // pointer can be pushed at it, and that push is what starts the pairing.
        var seen = Set<DeviceID>()
        var out: [ScreenLayoutGrid.Placement] = []
        for peer in peers {
            guard let id = peer.deviceID, peer.isCompatible,
                  grid.placement(of: id) == nil, seen.insert(id).inserted else { continue }
            out.append(ScreenLayoutGrid.Placement(id: id,
                                                  position: GridPosition(column: 0, row: 0),
                                                  name: peer.name))
        }
        for stored in PairingStore.peers()
        where grid.placement(of: stored.id) == nil && seen.insert(stored.id).inserted {
            out.append(ScreenLayoutGrid.Placement(id: stored.id,
                                                  position: GridPosition(column: 0, row: 0),
                                                  name: stored.name))
        }
        return out
    }

    /// Keep the arrangement showing a Mac's real name.
    func renamePlacement(_ id: DeviceID, to name: String) {
        guard !name.isEmpty, grid.placement(of: id)?.name != name else { return }
        grid.rename(id, to: name)
        LayoutStore.save(grid)
    }

    func saveLayout() {
        LayoutStore.save(grid)
        session?.updateLayout(grid)
    }

    /// Discovery is the freshest source of names, so reconcile against it whenever the
    /// peer list changes. Without this a Mac stored under a placeholder keeps that
    /// placeholder even though its real name is being advertised.
    private func reconcilePlacementNames() {
        for peer in peers {
            guard let id = peer.deviceID else { continue }
            renamePlacement(id, to: peer.name)
        }
    }

    func moveMac(_ id: DeviceID, to position: GridPosition) {
        // Discovery first: it is the live name, where the other two may hold a
        // placeholder written before the name was known.
        let name = peers.first { $0.deviceID == id }?.name
            ?? grid.placement(of: id)?.name
            ?? PairingStore.peers().first { $0.id == id }?.name
            ?? "Unknown Mac"
        grid.place(id, name: name, at: position)
        LayoutStore.save(grid)
        // The capture layer decides edges from this, so it must see the change now,
        // and the other Macs share this arrangement so they need it too.
        session?.updateLayout(grid)
    }


    /// Which edge of this Mac leads to `peer`, from the arrangement. Nil when the two
    /// are not placed side by side, which is the honest answer: there is no route.
    func edge(toward peer: DiscoveredPeer) -> ScreenEdge? {
        guard let id = peerIdentity(for: peer) else { return nil }
        return grid.edge(from: localDeviceID, to: id)
    }

    private func peerIdentity(for peer: DiscoveredPeer) -> DeviceID? { peer.deviceID }

    func isPaired(_ peer: DiscoveredPeer) -> Bool {
        guard let id = peer.deviceID else { return false }
        return PairingStore.peers().contains { $0.id == id }
    }

    func isPlaced(_ peer: DiscoveredPeer) -> Bool {
        guard let id = peer.deviceID else { return false }
        return grid.placement(of: id) != nil
    }

    /// What the user needs to do next with this Mac, or nil when it is ready to use.
    func nextStep(for peer: DiscoveredPeer) -> String? {
        if let reason = unusableReason(for: peer) { return reason }
        if !isPlaced(peer) { return "Add it in Arrange screens…" }
        if !isPaired(peer) { return "Move the pointer to it to connect" }
        return nil
    }

    /// Why a discovered peer cannot be used, or nil if it is usable.
    func unusableReason(for peer: DiscoveredPeer) -> String? {
        if !peer.isCompatible {
            return peer.protocolVersion == nil
                ? "Could not read its details"
                : "Different Station version"
        }
        if !peer.isPairable { return "Not ready to pair" }
        return nil
    }

    private func makeSession() -> SessionController {
        let session = SessionController(deviceName: deviceName)
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
            statusMessage = peers.isEmpty ? "Looking for other Macs…" : "Ready"
        case .approvalRequested(let peer, let name, let code):
            pendingApproval = (peer, name, code)
            statusMessage = "\(name) wants to join"
            Task { await approvePending() }
        case .awaitingApproval(let name, let code):
            awaitingApproval = (name, code)
            statusMessage = "Waiting for approval on \(name)"
            // On screen by itself: the code exists to be compared against the other
            // Mac, and one buried in a popover is one nobody compares.
            codePanel.show(name: name, code: code)
        case .paired(let name):
            pendingApproval = nil
            awaitingApproval = nil
            codePanel.hide()
            statusMessage = "Paired with \(name)"
        case .peerRenamed(let peer, let name):
            renamePlacement(peer, to: name)
        case .keyboardUnblocked:
            // Clear it rather than leaving a stale complaint about a fixed problem.
            if lastError?.contains("Secure Keyboard Entry") == true { lastError = nil }
        case .keyboardUnblocked:
            // Clear it rather than leaving a stale complaint about a fixed problem.
            if lastError?.contains("Secure Keyboard Entry") == true { lastError = nil }
        case .keyboardBlocked:
            lastError = "Another app has Secure Keyboard Entry turned on, so keystrokes "
                      + "cannot be sent to the other Mac. Terminal's Secure Keyboard "
                      + "Entry setting is the usual cause."
        case .layoutChanged(let incoming):
            // Already applied to the capture layer by the session; store and show it.
            grid = incoming
            LayoutStore.save(incoming)
        case .peerConnected(let name):
            awaitingApproval = nil
            codePanel.hide()
            connectedPeer = name
            statusMessage = "Connected to \(name)"
        case .peerDisconnected(let name, let reason):
            codePanel.hide()
            connectedPeer = nil
            controlIsRemote = false
            statusMessage = reason.map { "\(name): \($0)" } ?? "\(name) disconnected"
        case .controlMoved(let remote, let peer):
            controlIsRemote = remote
            statusMessage = remote ? "Control is on \(peer ?? "another Mac")" : "Control is here"
        case .clipboardSynced(let sent, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            lastClipboardActivity = sent ? "Clipboard sent (\(size))" : "Clipboard received (\(size))"
        case .clipboardSkipped(let reason):
            lastClipboardActivity = reason
        case .failed(let message):
            codePanel.hide()
            lastError = message
            statusMessage = "Failed"
        }
    }

    private static func describe(_ event: SessionController.Event) -> String {
        switch event {
        case .listening(let port):          return "listening on \(port)"
        case .approvalRequested(_, let n, _): return "\(n) asked to join"
        case .awaitingApproval(let n, _):   return "waiting for approval on \(n)"
        case .paired(let n):                return "paired with \(n)"
        case .peerConnected(let n):         return "connected to \(n)"
        case .peerRenamed(_, let n):        return "peer is named \(n)"
        case .layoutChanged:                return "arrangement updated by another Mac"
        case .keyboardBlocked:              return "keyboard blocked by secure input"
        case .keyboardUnblocked:            return "secure input released"
        case .peerDisconnected(let n, _):   return "\(n) disconnected"
        case .controlMoved(let remote, _):  return remote ? "control -> peer" : "control -> here"
        case .clipboardSynced(let sent, let b): return "clipboard \(sent ? "sent" : "received") \(b)B"
        case .clipboardSkipped(let r):      return "clipboard skipped: \(r)"
        case .failed(let m):                return "FAILED: \(m)"
        }
    }

    /// Reflects only whether Station is active, deliberately not where the pointer is.
    ///
    /// An icon that changed as control moved was flickering during ordinary use, and
    /// nobody is looking at this Mac's menu bar at the moment the pointer leaves it.
    /// Where control currently sits is shown inside the popover instead, where it is
    /// only read when someone goes looking for it.
    var menuBarSymbol: String {
        isRunning ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash"
    }
}
