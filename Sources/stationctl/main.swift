import Foundation
import Network
import CoreGraphics
import StationKit
import StationInput

// Station command-line driver. `secondary` receives and injects, `primary` captures and
// forwards. Both drive the same SessionController the menu bar app uses.

func log(_ tag: String, _ message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(tag.padding(toLength: 9, withPad: " ", startingAt: 0)) \(message)")
    fflush(stdout)
}

func flag(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Show the SAS and wait for the user to confirm it matches the other Mac.
///
/// The digits are a comparison value, not a secret: an attacker who learns them gains
/// nothing. What matters is that a machine-in-the-middle cannot make both Macs show the
/// same value, so a mismatch means someone is interposed.
func promptForConfirmation(_ sas: String, confirm: @escaping @Sendable () -> Void) {
    print("")
    print("  ┌──────────────────────────────────────────────┐")
    print("  │  Confirm this matches the OTHER Mac:          │")
    print("  │                                              │")
    print("  │                  \(sas)                      │")
    print("  │                                              │")
    print("  │  Type  yes  to pair, anything else to abort.  │")
    print("  └──────────────────────────────────────────────┘")
    print("")
    fflush(stdout)

    // With no terminal attached, readLine() returns nil immediately. Treating that as a
    // rejection would tear down a perfectly good connection, so hold instead and say
    // what is needed. Never auto-confirm: that would defeat the check entirely.
    guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
        log("pairing", "no terminal attached — run this in a terminal to confirm pairing")
        return
    }

    DispatchQueue.global().async {
        guard let line = readLine() else {
            log("pairing", "stdin closed before confirmation; connection left pending")
            return
        }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if answer == "yes" || answer == "y" {
            confirm()
        } else {
            log("pairing", "ABORTED — codes did not match")
            exit(1)
        }
    }
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"

switch command {

case "secondary":
    let session = SessionController(deviceName: Host.current().localizedName ?? "Mac")
    session.installTerminationHandlers()

    session.onEvent = { event in
        switch event {
        case .listening(let port):
            log("secondary", "listening on port \(port)")
            print("")
            print("  Run on the primary Mac:")
            print("    stationctl primary --host <this-mac-ip> --port \(port) --edge right")
            print("")
        case .needsConfirmation(let sas):
            promptForConfirmation(sas) { session.confirmPairing() }
        case .paired(let name):
            log("secondary", "PAIRED with \(name) — future connections need no confirmation")
        case .connected(let name):
            log("secondary", "primary connected: \(name)")
        case .disconnected(let reason):
            log("secondary", "disconnected\(reason.map { ": \($0)" } ?? "")")
        case .controlMoved(let remote):
            log("secondary", remote ? "control ARRIVED" : "control LEFT")
        case .armed:
            break
        case .clipboardSynced(let sent, let bytes):
            log("secondary", "clipboard \(sent ? "sent" : "received") (\(bytes) bytes)")
        case .clipboardSkipped(let reason):
            log("secondary", "clipboard skipped: \(reason)")
        case .failed(let message):
            log("secondary", "failed: \(message)")
        }
    }
    session.clipboardSyncEnabled = CommandLine.arguments.contains("--clipboard")
    if session.clipboardSyncEnabled { log("secondary", "clipboard sync ON") }
    log("secondary", "identity \(session.publicIdentity.prefix(4).map { String(format: "%02x", $0) }.joined())")
    log("secondary", "displays: \(ScreenGeometry.localScreens().screens.count), bounds \(ScreenGeometry.globalBounds)")
    session.startReceiving()
    CFRunLoopRun()

case "primary":
    guard let host = flag("host"), let portString = flag("port"), let port = UInt16(portString) else {
        print("usage: stationctl primary --host <ip> --port <port> [--edge right]")
        exit(2)
    }
    let edge = ScreenEdge(rawValue: flag("edge") ?? "right") ?? .right
    let session = SessionController(deviceName: Host.current().localizedName ?? "Mac")
    session.installTerminationHandlers()

    // Reuse a pinned identity for this peer if we have paired with it before.
    let known = PairingStore.peers().first
    if known != nil { log("primary", "using pinned identity for \(known!.name)") }

    session.onEvent = { event in
        switch event {
        case .needsConfirmation(let sas):
            promptForConfirmation(sas) { session.confirmPairing() }
        case .paired(let name):
            log("primary", "PAIRED with \(name)")
        case .armed:
            log("primary", "capture ARMED")
            print("")
            print("  Move the pointer off the \(edge.rawValue) edge to take over the peer.")
            print("  Control-Option-Escape forces control back at any time.")
            print("")
        case .connected(let name):
            log("primary", "connected to \(name)")
        case .controlMoved(let remote):
            log("primary", remote ? "control -> PEER" : "control -> LOCAL")
        case .disconnected(let reason):
            log("primary", "disconnected\(reason.map { ": \($0)" } ?? "")")
        case .clipboardSynced(let sent, let bytes):
            log("primary", "clipboard \(sent ? "sent" : "received") (\(bytes) bytes)")
        case .clipboardSkipped(let reason):
            log("primary", "clipboard skipped: \(reason)")
        case .failed(let message):
            log("primary", "failed: \(message)")
            exit(1)
        case .listening:
            break
        }
    }
    session.clipboardSyncEnabled = CommandLine.arguments.contains("--clipboard")
    if session.clipboardSyncEnabled { log("primary", "clipboard sync ON") }
    log("primary", "identity \(session.publicIdentity.prefix(4).map { String(format: "%02x", $0) }.joined())")
    log("primary", "local bounds \(ScreenGeometry.globalBounds), peer on \(edge.rawValue) edge")
    session.startSending(host: host, port: port, edge: edge,
                         expectedPeerIdentity: known?.publicKey)
    CFRunLoopRun()

case "connect":
    // Handshake against a running secondary without arming any input capture, so the
    // connection path can be tested safely on a single Mac.
    guard let host = flag("host"), let portString = flag("port"), let port = UInt16(portString),
          let nwPort = NWEndpoint.Port(rawValue: port) else {
        print("usage: stationctl connect --host <ip> --port <port>")
        exit(2)
    }
    let identity = Identity.generate()
    let link = StationLink(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                           identity: identity)
    link.onError = { log("connect", "error: \($0)") }
    link.onPeerIdentity = { key, known in
        log("connect", "peer identity \(key.prefix(4).map { String(format: "%02x", $0) }.joined()) known=\(known)")
    }
    link.onMessage = { type, payload in
        log("connect", "recv \(type) \(payload.count) bytes")
        if type == .screens, let set = try? JSONDecoder().decode(ScreenSet.self, from: payload) {
            log("connect", "peer screens: \(set.screens.count), bounds \(set.bounds)")
            log("connect", "SUCCESS: handshake, encryption and app messaging all work")
            exit(0)
        }
    }
    link.onPhase = { phase in
        log("connect", "phase \(phase)")
        switch phase {
        case .awaitingConfirmation(let sas):
            log("connect", "SAS \(sas) — auto-confirming for this diagnostic")
            link.confirmPairing()
        case .ready:
            try? link.send(.hello, json: Hello(deviceID: UUID(), deviceName: "stationctl-connect",
                                               role: .primary))
        case .failed(let reason):
            log("connect", "FAILED: \(reason)"); exit(1)
        default:
            break
        }
    }
    link.start()
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { log("connect", "TIMED OUT"); exit(1) }
    dispatchMain()

case "peers":
    let peers = PairingStore.peers()
    if peers.isEmpty {
        log("peers", "no paired Macs stored")
    } else {
        for p in peers {
            log("peers", "\(p.name) fingerprint=\(p.fingerprint) edge=\(p.edge.rawValue) paired=\(p.pairedAt)")
        }
    }
    exit(0)

case "forget":
    // A pinned identity that no longer matches is rejected outright, which is correct
    // but unhelpful if the stored entry is simply stale from an abandoned pairing.
    let peers = PairingStore.peers()
    for p in peers {
        PairingStore.remove(publicKey: p.publicKey)
        log("forget", "removed \(p.name) (\(p.fingerprint))")
    }
    log("forget", "\(peers.count) pairing(s) cleared; next connection will pair afresh")
    exit(0)

case "edge-test":
    // Where does the cursor actually land when we inject at each screen edge? Screen
    // edge behaviours (auto-hidden Dock, menu bar, hot corners) only trigger when the
    // pointer reaches the true boundary row or column.
    let bounds = ScreenGeometry.globalBounds
    log("edge", "global bounds \(bounds)")
    let injection = EventInjection(bounds: bounds)
    let probes: [(String, NormalizedPoint)] = [
        ("centre", NormalizedPoint(x: 0.5, y: 0.5)),
        ("bottom", NormalizedPoint(x: 0.5, y: 1.0)),
        ("top",    NormalizedPoint(x: 0.5, y: 0.0)),
        ("left",   NormalizedPoint(x: 0.0, y: 0.5)),
        ("right",  NormalizedPoint(x: 1.0, y: 0.5)),
    ]
    for (name, point) in probes {
        let target = point.absolute(in: bounds)
        injection.enter(at: point)
        usleep(250_000)
        let actual = ScreenGeometry.currentCursor
        let delta = String(format: "%.0f,%.0f", actual.x - target.x, actual.y - target.y)
        log("edge", "\(name.padding(toLength: 7, withPad: " ", startingAt: 0)) "
                  + "target=(\(Int(target.x)),\(Int(target.y))) "
                  + "actual=(\(Int(actual.x)),\(Int(actual.y))) delta=(\(delta))")
    }
    exit(0)

case "dock-test":
    // Synthetic CGEventPost moves the logical cursor but does not reveal an auto-hidden
    // Dock. Other APIs move the pointer at different layers, so try each in turn and
    // see which, if any, macOS honours for edge-triggered behaviour.
    let display = CGDisplayBounds(CGMainDisplayID())
    let x = display.midX
    let home = CGPoint(x: x, y: display.midY)
    let edge = CGPoint(x: x, y: display.maxY)

    func rest() {
        CGWarpMouseCursorPosition(home)
        usleep(900_000)
    }

    log("dock", "display \(display) — watch the bottom of the screen")
    print("")

    rest()
    log("dock", "[1/3] posted mouseMoved events ...")
    for y in stride(from: display.maxY - 250, through: display.maxY, by: 6) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(12_000)
    }
    for _ in 0..<30 {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: edge, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
    sleep(1)

    rest()
    log("dock", "[2/3] CGWarpMouseCursorPosition ...")
    for y in stride(from: display.maxY - 250, through: display.maxY, by: 6) {
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        usleep(12_000)
    }
    for _ in 0..<30 { CGWarpMouseCursorPosition(edge); usleep(50_000) }
    sleep(1)

    rest()
    log("dock", "[3/3] CGDisplayMoveCursorToPoint ...")
    // Display-relative, so the point must be in display coordinates.
    for y in stride(from: display.height - 250, through: display.height - 1, by: 6) {
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: x, y: y))
        usleep(12_000)
    }
    for _ in 0..<30 {
        CGDisplayMoveCursorToPoint(CGMainDisplayID(), CGPoint(x: x, y: display.height - 1))
        usleep(50_000)
    }
    sleep(1)
    rest()

    print("")
    log("dock", "which step, if any, revealed the Dock? (1 posted, 2 warp, 3 display-move)")
    exit(0)

case "discover":
    let browser = PeerBrowser()
    browser.onPeersChanged = { peers in
        if peers.isEmpty { log("discover", "no peers"); return }
        for p in peers {
            log("discover", "\(p.name) at \(p.host):\(p.port) "
                          + "id=\(p.identityFingerprint ?? "MISSING") "
                          + "v=\(p.protocolVersion.map(String.init) ?? "MISSING") "
                          + "compatible=\(p.isCompatible)")
        }
    }
    browser.start()
    log("discover", "browsing \(stationBonjourType) for 12s")
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
    CFRunLoopRun()

case "probe":
    // Loopback check of the handshake, encryption, and framing.
    let serverIdentity = Identity.generate()
    let clientIdentity = Identity.generate()
    nonisolated(unsafe) var serverLink: StationLink?

    let listener = StationListener(deviceName: "probe-secondary", identity: serverIdentity)
    listener.onError = { log("listener", "error: \($0)") }
    listener.onLink = { link in
        serverLink = link
        link.onPhase = { phase in
            log("server", "phase \(phase)")
            if case .awaitingConfirmation = phase { link.confirmPairing() }
        }
        link.onMessage = { type, data in
            log("server", "recv \(type) \(data.count) bytes")
            if type == .input, let event = InputEvent.decode(data) {
                log("server", "  -> type=\(event.eventType) blob=\(event.eventData.count)B")
                log("probe", "SUCCESS: encrypted channel carried an opaque gesture blob")
                exit(0)
            }
        }
    }
    try! listener.start(advertise: false)
    var bound: NWEndpoint.Port?
    for _ in 0..<200 { if let p = listener.port { bound = p; break }; usleep(50_000) }
    guard let bound else { log("listener", "never bound"); exit(1) }
    log("listener", "bound on \(bound)")

    let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: bound),
                             identity: clientIdentity)
    client.onPhase = { phase in
        log("client", "phase \(phase)")
        if case .awaitingConfirmation(let sas) = phase {
            log("client", "SAS \(sas)")
            client.confirmPairing()
        }
        if phase == .ready {
            let blob = Data((0..<260).map { UInt8($0 % 256) })
            client.send(.input, InputEvent(eventType: 29, normalizedX: 0.5, normalizedY: 0.25,
                                           deltaX: 1.5, deltaY: -2.5, eventData: blob).encode())
        }
    }
    client.onError = { log("client", "error: \($0)") }
    client.start()
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { log("probe", "TIMED OUT"); exit(1) }
    dispatchMain()

case "cursor-selftest":
    let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "exit"
    CursorControl.installSafetyNet()
    log("cursor", "background hiding available: \(CursorControl.canHideInBackground)")
    CursorControl.hide()
    log("cursor", "hidden; mode=\(mode)")
    switch mode {
    case "exit":
        log("cursor", "exiting normally in 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    case "signal":
        log("cursor", "waiting for SIGTERM")
    default:
        log("cursor", "unknown mode"); exit(2)
    }
    CFRunLoopRun()

default:
    print("""
    stationctl — Station command-line driver

      stationctl secondary
          Receive and inject input. Prints the port to use on the primary.

      stationctl primary --host <ip> --port <port> [--edge right]
          Capture input and forward it when the pointer crosses the given edge.
          Control-Option-Escape always returns control locally.

      stationctl connect --host <ip> --port <port>
          Handshake against a secondary without capturing input. Safe on one Mac.

      stationctl peers
          List paired Macs and their identity fingerprints.

      stationctl forget
          Forget all paired Macs so the next connection pairs afresh.

      stationctl dock-test
          Move the cursor to the bottom edge with synthetic events and watch
          whether an auto-hidden Dock reveals. Run on the receiving Mac.

      stationctl discover
          Browse for Station peers and report what resolved.

      stationctl probe
          Loopback handshake and transport self-test.

      stationctl cursor-selftest [exit|signal]
          Hide the cursor, then verify it is restored on that exit path.

    First pairing shows six digits on both Macs. They are a comparison, not a
    secret: confirm they match and the peer identity is pinned for future use.
    """)
}
