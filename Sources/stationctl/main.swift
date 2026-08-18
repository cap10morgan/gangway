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
    let pairing = PairingString(code: flag("code") ?? Pairing.generateCode(),
                                salt: Pairing.generateSalt())
    let injection = EventInjection()
    let screens = ScreenGeometry.localScreens()

    log("secondary", "displays: \(screens.screens.count), bounds \(screens.bounds)")
    print("")
    print("  Run this on the primary Mac:")
    print("    stationctl primary --host <this-mac-ip> --port <port> --pair \(pairing.encoded) --edge right")
    print("")

    nonisolated(unsafe) var link: StationLink?
    let listener = StationListener(deviceName: Host.current().localizedName ?? "Mac")
    listener.onError = { log("secondary", "listener error: \($0)") }
    listener.onReady = { port in
        log("secondary", "listening on port \(port) — waiting for primary")
        print("")
        print("    stationctl primary --host <this-mac-ip> --port \(port) --pair \(pairing.encoded) --edge right")
        print("")
    }
    listener.onLink = { newLink in
        log("secondary", "primary connected from \(newLink.endpointDescription)")
        link = newLink
        newLink.onStateChange = { log("secondary", "link \($0)") }
        newLink.onError = { log("secondary", "link error: \($0)") }
        newLink.onMessage = { type, payload in
            switch type {
            case .hello:
                if let hello = try? JSONDecoder().decode(Hello.self, from: payload) {
                    log("secondary", "hello from \(hello.deviceName) (protocol \(hello.protocolVersion))")
                }
                // Tell the primary our geometry so it can scale pointer motion.
                try? newLink.send(.screens, json: screens)

            case .enterScreen:
                guard let msg = EnterScreen.decode(payload) else { return }
                let at = NormalizedPoint(x: msg.normalizedX, y: msg.normalizedY)
                injection.enter(at: at)
                log("secondary", "control ARRIVED at \(String(format: "%.3f,%.3f", at.x, at.y))")

            case .leaveScreen:
                injection.leave()
                log("secondary", "control LEFT")

            case .input:
                guard let event = InputEvent.decode(payload) else { return }
                if !injection.inject(event) {
                    log("secondary", "failed to rehydrate event type \(event.eventType)")
                }

            default:
                break
            }
        }
    }
    do {
        try listener.start(credential: .code(pairing.code), salt: pairing.salt)
    } catch {
        log("secondary", "failed to start: \(error)"); exit(1)
    }
    CFRunLoopRun()

// MARK: - primary: capture and forward

case "primary":
    guard let host = flag("host"), let portString = flag("port"),
          let port = NWEndpoint.Port(portString),
          let pairString = flag("pair"), let pairing = PairingString(encoded: pairString) else {
        print("usage: stationctl primary --host <ip> --port <port> --pair <code.salt> [--edge right]")
        exit(2)
    }
    let edge = Edge(rawValue: flag("edge") ?? "right") ?? .right
    let peerID = UUID()

    let capture = EventCapture(layout: Layout(placements: [edge: peerID]))
    log("primary", "local bounds \(ScreenGeometry.globalBounds), peer on \(edge.rawValue) edge")

    let link = StationLink(endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                           credential: .code(pairing.code), salt: pairing.salt)

    capture.onEvent = { event in link.send(.input, event.encode()) }
    capture.onEnterPeer = { _, at in
        link.send(.enterScreen, EnterScreen(normalizedX: at.x, normalizedY: at.y).encode())
        log("primary", "control -> PEER at \(String(format: "%.3f,%.3f", at.x, at.y))")
    }
    capture.onReturnLocal = { edge, _ in
        link.send(.leaveScreen, Data())
        log("primary", "control -> LOCAL (exited \(edge.rawValue))")
    }
    capture.onEscapeHatch = { log("primary", "ESCAPE HATCH — control forced back locally") }
    capture.onTapDisabled = { log("primary", "tap was disabled by the system; re-armed") }

    link.onError = { log("primary", "error: \($0)") }
    link.onStateChange = { state in
        log("primary", "link \(state)")
        if state == .ready {
            let hello = Hello(deviceID: UUID(),
                              deviceName: Host.current().localizedName ?? "Mac",
                              role: .primary)
            try? link.send(.hello, json: hello)
        }
        if case .failed(let reason) = state {
            log("primary", "giving up: \(reason)")
            // capture.stop() must run on the run-loop thread that owns the tap.
            DispatchQueue.main.async { capture.stop(); exit(1) }
        }
    }
    link.onMessage = { type, payload in
        guard type == .screens,
              let peerScreens = try? JSONDecoder().decode(ScreenSet.self, from: payload) else { return }
        // The tap must be created on the thread that runs the run loop.
        DispatchQueue.main.async {
            capture.setPeerBounds(peerScreens.bounds, for: peerID)
            do {
                try capture.start()
                log("primary", "peer bounds \(peerScreens.bounds) — capture ARMED")
                print("")
                print("  Move the pointer off the \(edge.rawValue) edge to take over the peer.")
                print("  Control-Option-Escape forces control back at any time.")
                print("")
            } catch {
                log("primary", "\(error.localizedDescription)")
                exit(1)
            }
        }
    }
    // Safety: while forwarding, the cursor is hidden and decoupled from the physical
    // mouse. If we exit without releasing it the user is left with what looks like a
    // broken pointer, so make sure Ctrl-C and SIGTERM always tear the capture down.
    nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log("primary", "shutting down — releasing cursor")
            capture.stop()
            link.cancel()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    link.start()
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

default:
    print("""
    stationctl — Station command-line driver

      stationctl secondary [--code 123456]
          Receive and inject input. Prints the pairing string to use on the primary.

      stationctl primary --host <ip> --port <port> --pair <code.salt> [--edge right]
          Capture input and forward it when the pointer crosses the given edge.
          Control-Option-Escape always returns control locally.

      stationctl probe
          Loopback transport self-test.
    """)
}
