import Foundation
import Network
import CoreGraphics
import StationKit
import StationInput

// Station command-line driver. `secondary` receives and injects, `primary` captures
// and forwards. This is the full vertical slice without the GUI, which makes it the
// fastest way to test real two-Mac behaviour and to diagnose the transport.

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

/// Pairing material the primary needs before TLS can be established. The salt cannot
/// travel inside the encrypted channel because it is required to derive the key, so it
/// is public by design. The GUI will publish it in the Bonjour TXT record; the CLI
/// prints it for the user to copy.
struct PairingString {
    let code: String
    let salt: Data

    var encoded: String { "\(code).\(salt.map { String(format: "%02x", $0) }.joined())" }

    init(code: String, salt: Data) {
        self.code = code
        self.salt = salt
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: ".")
        guard parts.count == 2, parts[0].count == Pairing.codeDigits else { return nil }
        let hex = String(parts[1])
        guard hex.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.code = String(parts[0])
        self.salt = bytes
    }
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"

switch command {

// MARK: - secondary: receive and inject

case "secondary":
    let session = SessionController(deviceName: Host.current().localizedName ?? "Mac")
    session.installTerminationHandlers()
    nonisolated(unsafe) var advertised = false

    session.onEvent = { event in
        switch event {
        case .listening(let code, let salt, let port):
            let pair = PairingString(code: code, salt: salt).encoded
            log("secondary", "listening on port \(port)")
            if !advertised {
                advertised = true
                print("")
                print("  Run this on the primary Mac:")
                print("    stationctl primary --host <this-mac-ip> --port \(port) --pair \(pair) --edge right")
                print("")
            }
        case .connected(let peerName):
            log("secondary", "primary connected: \(peerName)")
        case .disconnected(let reason):
            log("secondary", "disconnected\(reason.map { ": \($0)" } ?? "")")
        case .controlMoved(let remote):
            log("secondary", remote ? "control ARRIVED" : "control LEFT")
        case .armed:
            break
        case .failed(let message):
            log("secondary", "failed: \(message)")
        }
    }
    log("secondary", "displays: \(ScreenGeometry.localScreens().screens.count), "
                   + "bounds \(ScreenGeometry.globalBounds)")
    session.startReceiving(code: flag("code"))
    CFRunLoopRun()

// MARK: - primary: capture and forward

case "primary":
    guard let host = flag("host"), let portString = flag("port"), let port = UInt16(portString),
          let pairString = flag("pair"), let pairing = PairingString(encoded: pairString) else {
        print("usage: stationctl primary --host <ip> --port <port> --pair <code.salt> [--edge right]")
        exit(2)
    }
    let edge = ScreenEdge(rawValue: flag("edge") ?? "right") ?? .right
    let session = SessionController(deviceName: Host.current().localizedName ?? "Mac")
    session.installTerminationHandlers()

    session.onEvent = { event in
        switch event {
        case .armed:
            log("primary", "capture ARMED")
            print("")
            print("  Move the pointer off the \(edge.rawValue) edge to take over the peer.")
            print("  Control-Option-Escape forces control back at any time.")
            print("")
        case .connected(let peerName):
            log("primary", "connected to \(peerName)")
        case .controlMoved(let remote):
            log("primary", remote ? "control -> PEER" : "control -> LOCAL")
        case .disconnected(let reason):
            log("primary", "disconnected\(reason.map { ": \($0)" } ?? "")")
        case .failed(let message):
            log("primary", "failed: \(message)")
            exit(1)
        case .listening:
            break
        }
    }
    log("primary", "local bounds \(ScreenGeometry.globalBounds), peer on \(edge.rawValue) edge")
    session.startSending(host: host, port: port, code: pairing.code, salt: pairing.salt, edge: edge)
    CFRunLoopRun()

case "discover":
    // Browse for peers and report exactly what was resolved, including whether the
    // pairing salt came through. Empty output means discovery, not pairing, is at fault.
    let browser = PeerBrowser()
    browser.onPeersChanged = { peers in
        if peers.isEmpty {
            log("discover", "no peers")
            return
        }
        for p in peers {
            log("discover", "\(p.name) at \(p.host):\(p.port) "
                          + "salt=\(p.salt.map { "\($0.count)B" } ?? "MISSING") "
                          + "v=\(p.protocolVersion.map(String.init) ?? "MISSING") "
                          + "compatible=\(p.isCompatible) pairable=\(p.isPairable)")
        }
    }
    browser.start()
    log("discover", "browsing \(stationBonjourType) for 12s")
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
    CFRunLoopRun()

case "probe":
    // Loopback transport check: pairing, framing, and an opaque gesture blob.
    let salt = Pairing.generateSalt()
    let credential = PairingCredential.code("123456")
    nonisolated(unsafe) var serverLink: StationLink?
    let listener = StationListener(deviceName: "probe-primary")
    listener.onError = { log("listener", "error: \($0)") }
    listener.onLink = { link in
        serverLink = link
        link.onStateChange = { log("server", "state \($0)") }
        link.onMessage = { type, data in
            log("server", "recv \(type) \(data.count) bytes")
            if type == .input, let event = InputEvent.decode(data) {
                log("server", "  -> type=\(event.eventType) blob=\(event.eventData.count)B")
                exit(0)
            }
        }
    }
    try! listener.start(credential: credential, salt: salt, advertise: false)
    var bound: NWEndpoint.Port?
    for _ in 0..<200 { if let p = listener.port { bound = p; break }; usleep(50_000) }
    guard let bound else { log("listener", "never bound"); exit(1) }
    log("listener", "bound on \(bound)")

    let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: bound),
                             credential: credential, salt: salt)
    client.onStateChange = { state in
        log("client", "state \(state)")
        if state == .ready {
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
    // Verifies that a hidden cursor is restored on exit. A leaked hide leaves the user
    // with no pointer, so this path is worth being able to check on demand.
    let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "exit"
    CursorControl.installSafetyNet()
    log("cursor", "background hiding available: \(CursorControl.canHideInBackground)")
    CursorControl.hide()
    log("cursor", "hidden; mode=\(mode)")
    switch mode {
    case "exit":
        // Normal termination: atexit must unhide.
        log("cursor", "exiting normally in 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    case "signal":
        // Wait to be signalled; the DispatchSource handler must unhide.
        log("cursor", "waiting for SIGTERM")
    default:
        log("cursor", "unknown mode")
        exit(2)
    }
    CFRunLoopRun()

default:
    print("""
    stationctl — Station command-line driver

      stationctl secondary [--code 123456]
          Receive and inject input. Prints the pairing string to use on the primary.

      stationctl primary --host <ip> --port <port> --pair <code.salt> [--edge right]
          Capture input and forward it when the pointer crosses the given edge.
          Control-Option-Escape always returns control locally.

      stationctl discover
          Browse for Station peers and report what resolved.

      stationctl probe
          Loopback transport self-test.

      stationctl cursor-selftest [exit|signal]
          Hide the cursor, then verify it is restored on that exit path.
    """)
}
