import Foundation
import Network
import StationKit

// Diagnostic CLI for the Station transport. `probe` runs a loopback pairing and
// reports every state transition and error, which is far more legible than watching
// an XCTest expectation time out.

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "probe"

func log(_ tag: String, _ message: String) {
    let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    print("[\(stamp)] \(tag.padding(toLength: 8, withPad: " ", startingAt: 0)) \(message)")
}

switch command {
case "probe":
    let salt = Pairing.generateSalt()
    let code = "123456"
    let credential = PairingCredential.code(code)
    log("probe", "pairing code \(code), salt \(salt.prefix(4).map { String(format: "%02x", $0) }.joined())")

    nonisolated(unsafe) var serverLink: StationLink?
    let listener = StationListener(deviceName: "probe-primary")
    listener.onError = { log("listener", "error: \($0)") }
    listener.onLink = { link in
        log("server", "incoming connection from \(link.endpointDescription)")
        serverLink = link
        link.onStateChange = { log("server", "state \($0)") }
        link.onError = { log("server", "error: \($0)") }
        link.onMessage = { type, data in
            log("server", "recv \(type) \(data.count) bytes")
            if type == .input, let event = InputEvent.decode(data) {
                log("server", "  -> input type=\(event.eventType) blob=\(event.eventData.count)B")
                exit(0)
            }
        }
    }
    do {
        try listener.start(credential: credential, salt: salt, advertise: false)
    } catch {
        log("listener", "start failed: \(error)"); exit(1)
    }

    // Wait for the listener to actually bind before dialing it.
    var port: NWEndpoint.Port?
    for _ in 0..<100 {
        if let p = listener.port { port = p; break }
        usleep(50_000)
    }
    guard let port else { log("listener", "never bound a port"); exit(1) }
    log("listener", "bound on port \(port)")

    let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                             credential: credential, salt: salt)
    client.onStateChange = { state in
        log("client", "state \(state)")
        if state == .ready {
            let blob = Data((0..<260).map { UInt8($0 % 256) })
            let event = InputEvent(eventType: 29, normalizedX: 0.5, normalizedY: 0.25,
                                   deltaX: 1.5, deltaY: -2.5, eventData: blob)
            client.send(.input, event.encode())
            log("client", "sent input event (\(blob.count)B blob)")
        }
    }
    client.onError = { log("client", "error: \($0)") }
    client.start()

    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        log("probe", "TIMED OUT")
        exit(1)
    }
    dispatchMain()

case "probe-wrong":
    // What does a peer with the wrong code actually observe? The security tests must
    // assert against real behaviour, not an assumed .failed transition.
    let salt = Pairing.generateSalt()
    nonisolated(unsafe) var serverLink: StationLink?
    let listener = StationListener(deviceName: "probe-primary")
    listener.onError = { log("listener", "error: \($0)") }
    listener.onLink = { link in
        log("server", "incoming connection")
        serverLink = link
        link.onStateChange = { log("server", "state \($0)") }
        link.onError = { log("server", "error: \($0)") }
    }
    try! listener.start(credential: .code("123456"), salt: salt, advertise: false)
    var port: NWEndpoint.Port?
    for _ in 0..<200 { if let p = listener.port { port = p; break }; usleep(50_000) }
    log("listener", "bound on port \(port!)")

    let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port!),
                             credential: .code("999999"), salt: salt)
    client.onStateChange = { log("client", "state \($0)") }
    client.onError = { log("client", "error: \($0)") }
    client.start()
    DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
        log("probe", "done observing"); exit(0)
    }
    dispatchMain()

default:
    print("usage: stationctl probe|probe-wrong")
}
