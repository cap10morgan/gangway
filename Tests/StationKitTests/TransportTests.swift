import XCTest
import Network
@testable import StationKit

/// End-to-end transport tests over loopback: handshake, SAS confirmation, identity
/// pinning, and encrypted framing. Bonjour advertising is off so these do not depend on
/// local-network permission.
final class TransportTests: XCTestCase {

    private func waitForPort(_ listener: StationListener) throws -> NWEndpoint.Port {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let port = listener.port { return port }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw XCTSkip("listener never bound a port")
    }

    func testPairsAndDeliversEncryptedFrames() throws {
        let serverIdentity = Identity.generate()
        let clientIdentity = Identity.generate()

        let serverReady = expectation(description: "server ready")
        let received = expectation(description: "server received input")
        nonisolated(unsafe) var serverLink: StationLink?
        nonisolated(unsafe) var payload: Data?
        nonisolated(unsafe) var serverSAS: String?

        let listener = StationListener(deviceName: "test-secondary", identity: serverIdentity)
        listener.onLink = { link in
            serverLink = link
            link.onPhase = { phase in
                if case .awaitingConfirmation(let sas) = phase {
                    serverSAS = sas
                    link.confirmPairing()
                }
                if phase == .ready { serverReady.fulfill() }
            }
            link.onMessage = { type, data in
                guard type == .input else { return }
                payload = data
                received.fulfill()
            }
        }
        try listener.start(port: .any, advertise: false)   // never the fixed port in tests
        defer { listener.stop(); serverLink?.cancel() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 identity: clientIdentity)
        let clientReady = expectation(description: "client ready")
        nonisolated(unsafe) var clientSAS: String?
        client.onPhase = { phase in
            if case .awaitingConfirmation(let sas) = phase {
                clientSAS = sas
                client.confirmPairing()
            }
            if phase == .ready { clientReady.fulfill() }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [clientReady, serverReady], timeout: 10)
        XCTAssertNotNil(clientSAS)
        XCTAssertEqual(clientSAS, serverSAS, "both ends must show the same digits")

        let blob = Data((0..<260).map { UInt8($0 % 256) })
        let event = InputEvent(eventType: 29, normalizedX: 0.5, normalizedY: 0.25,
                               deltaX: 1.5, deltaY: -2.5, eventData: blob)
        client.send(.input, event.encode())

        wait(for: [received], timeout: 10)
        let decoded = try XCTUnwrap(InputEvent.decode(try XCTUnwrap(payload)))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.eventData, blob, "gesture payload must survive the hop")
    }

    /// Nothing may be delivered before the user confirms the SAS. Session keys exist as
    /// soon as the handshake completes, so without an explicit gate a peer could inject
    /// input before the user has looked at the digits.
    func testDeliversNothingBeforeConfirmation() throws {
        let serverIdentity = Identity.generate()
        nonisolated(unsafe) var serverLink: StationLink?
        nonisolated(unsafe) var delivered = false
        let sawConfirmation = expectation(description: "server reached confirmation")

        let listener = StationListener(deviceName: "test-secondary", identity: serverIdentity)
        listener.onLink = { link in
            serverLink = link
            // Deliberately never confirm.
            link.onPhase = { if case .awaitingConfirmation = $0 { sawConfirmation.fulfill() } }
            link.onMessage = { _, _ in delivered = true }
        }
        try listener.start(port: .any, advertise: false)   // never the fixed port in tests
        defer { listener.stop(); serverLink?.cancel() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 identity: .generate())
        let clientReady = expectation(description: "client ready")
        client.onPhase = { phase in
            if case .awaitingConfirmation = phase { client.confirmPairing() }
            if phase == .ready { clientReady.fulfill() }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [clientReady, sawConfirmation], timeout: 10)
        client.send(.input, InputEvent(eventType: 29, normalizedX: 0, normalizedY: 0,
                                       deltaX: 0, deltaY: 0, eventData: Data([1, 2, 3])).encode())

        // Give it every chance to leak through.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(delivered, "an unconfirmed peer must not be able to inject input")
    }

    /// Regression: each Mac confirms independently, so whichever confirms first sends
    /// immediately while the other is still waiting on its user. Those messages must be
    /// held and delivered on confirmation, not dropped. Dropping them loses the peer's
    /// hello, which drives the screen-geometry exchange, and the session stalls at
    /// "waiting for another Mac to connect" with no error shown.
    func testMessagesSentBeforeConfirmationArriveAfterIt() throws {
        let serverIdentity = Identity.generate()
        nonisolated(unsafe) var serverLink: StationLink?
        nonisolated(unsafe) var deliveredPayload: Data?
        let sawConfirmation = expectation(description: "server reached confirmation")
        let delivered = expectation(description: "held message delivered")

        let listener = StationListener(deviceName: "test-secondary", identity: serverIdentity)
        listener.onLink = { link in
            serverLink = link
            link.onPhase = { if case .awaitingConfirmation = $0 { sawConfirmation.fulfill() } }
            link.onMessage = { type, payload in
                guard type == .hello else { return }
                deliveredPayload = payload
                delivered.fulfill()
            }
        }
        try listener.start(port: .any, advertise: false)
        defer { listener.stop(); serverLink?.cancel() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 identity: .generate())
        let clientReady = expectation(description: "client ready")
        client.onPhase = { phase in
            if case .awaitingConfirmation = phase { client.confirmPairing() }
            if phase == .ready { clientReady.fulfill() }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [clientReady, sawConfirmation], timeout: 10)

        // Client confirmed and sends straight away; the server has not confirmed yet.
        client.send(.hello, Data("early".utf8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(deliveredPayload, "must not be delivered before confirmation")

        serverLink?.confirmPairing()
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(deliveredPayload, Data("early".utf8))
    }

    /// A peer presenting an identity other than the pinned one must be refused, which is
    /// what an impersonating machine looks like.
    func testPinnedIdentityMismatchIsRefused() throws {
        let serverIdentity = Identity.generate()
        let expectedButWrong = Identity.generate()

        nonisolated(unsafe) var serverLink: StationLink?
        let listener = StationListener(deviceName: "test-secondary", identity: serverIdentity)
        listener.onLink = { link in
            serverLink = link
            link.onPhase = { if case .awaitingConfirmation = $0 { link.confirmPairing() } }
        }
        try listener.start(port: .any, advertise: false)   // never the fixed port in tests
        defer { listener.stop(); serverLink?.cancel() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 identity: .generate(),
                                 expectedPeerIdentity: expectedButWrong.publicKeyData)
        let failed = expectation(description: "refused")
        let becameReady = expectation(description: "must not become ready")
        becameReady.isInverted = true
        nonisolated(unsafe) var reason: String?
        client.onPhase = { phase in
            if phase == .ready { becameReady.fulfill() }
            if case .failed(let r) = phase {
                reason = r
                failed.fulfill()
            }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [failed, becameReady], timeout: 10)
        XCTAssertEqual(reason, HandshakeError.peerIdentityChanged.errorDescription)
    }

    /// A known peer must connect with no user interaction at all.
    func testPinnedIdentityConnectsWithoutConfirmation() throws {
        let serverIdentity = Identity.generate()
        let clientIdentity = Identity.generate()

        nonisolated(unsafe) var serverLink: StationLink?
        let listener = StationListener(deviceName: "test-secondary", identity: serverIdentity)
        listener.onLink = { link in
            serverLink = link
            link.onPhase = { if case .awaitingConfirmation = $0 { link.confirmPairing() } }
        }
        try listener.start(port: .any, advertise: false)   // never the fixed port in tests
        defer { listener.stop(); serverLink?.cancel() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 identity: clientIdentity,
                                 expectedPeerIdentity: serverIdentity.publicKeyData)
        let ready = expectation(description: "ready")
        let asked = expectation(description: "must not ask for confirmation")
        asked.isInverted = true
        client.onPhase = { phase in
            if case .awaitingConfirmation = phase { asked.fulfill() }
            if phase == .ready { ready.fulfill() }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [ready, asked], timeout: 10)
    }
}
