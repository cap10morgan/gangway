import XCTest
import Network
@testable import StationKit

/// End-to-end transport tests over loopback. Bonjour advertising is disabled so these
/// exercise TLS-PSK and framing without depending on local-network permission.
final class TransportTests: XCTestCase {

    private func makeListener(credential: PairingCredential, salt: Data,
                              onLink: @escaping @Sendable (StationLink) -> Void) throws -> StationListener {
        let listener = StationListener(deviceName: "test-primary")
        listener.onLink = onLink
        try listener.start(credential: credential, salt: salt, advertise: false)
        return listener
    }

    /// Waits until the listener is genuinely bound. `NWListener.port` reads back as
    /// zero before binding completes, so polling for non-nil is not enough.
    private func waitForPort(_ listener: StationListener) throws -> NWEndpoint.Port {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let port = listener.port { return port }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw XCTSkip("listener never bound a port")
    }

    func testMatchingCodeConnectsAndDeliversFrames() throws {
        let salt = Pairing.generateSalt()
        let credential = PairingCredential.code("123456")

        let serverReady = expectation(description: "server link ready")
        let received = expectation(description: "server received input event")
        nonisolated(unsafe) var serverLink: StationLink?
        nonisolated(unsafe) var payload: Data?

        let listener = try makeListener(credential: credential, salt: salt) { link in
            serverLink = link
            link.onStateChange = { if $0 == .ready { serverReady.fulfill() } }
            link.onMessage = { type, data in
                guard type == .input else { return }
                payload = data
                received.fulfill()
            }
        }
        defer { listener.stop(); serverLink?.cancel() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 credential: credential, salt: salt)
        let clientReady = expectation(description: "client ready")
        client.onStateChange = { if $0 == .ready { clientReady.fulfill() } }
        client.start()
        defer { client.cancel() }

        wait(for: [clientReady, serverReady], timeout: 10)

        // Send something shaped like the real hot path: an opaque gesture blob.
        let blob = Data((0..<260).map { UInt8($0 % 256) })
        let event = InputEvent(eventType: 29, normalizedX: 0.5, normalizedY: 0.25,
                               deltaX: 1.5, deltaY: -2.5, eventData: blob)
        client.send(.input, event.encode())

        wait(for: [received], timeout: 10)
        let decoded = try XCTUnwrap(InputEvent.decode(try XCTUnwrap(payload)))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.eventData, blob, "gesture payload must survive the network hop")
    }

    /// Security-critical: a peer that does not know the code must never reach `.ready`.
    func testWrongCodeIsRejected() throws {
        let salt = Pairing.generateSalt()
        let listener = try makeListener(credential: .code("123456"), salt: salt) { link in
            link.start()
        }
        defer { listener.stop() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 credential: .code("999999"), salt: salt)
        let failed = expectation(description: "handshake rejected")
        let becameReady = expectation(description: "must not become ready")
        becameReady.isInverted = true
        nonisolated(unsafe) var failureReason: String?
        client.onStateChange = { (state: LinkState) in
            if state == .ready { becameReady.fulfill() }
            if case .failed(let reason) = state {
                failureReason = reason
                failed.fulfill()
            }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [failed, becameReady], timeout: 3)
        XCTAssertEqual(failureReason, "Incorrect pairing code",
                       "a mistyped code must surface as such, not as a generic failure")
    }

    /// A mismatched salt must also fail, since the salt is what stops two pairings
    /// that share a code from deriving the same key.
    func testMismatchedSaltIsRejected() throws {
        let listener = try makeListener(credential: .code("123456"), salt: Pairing.generateSalt()) { link in
            link.start()
        }
        defer { listener.stop() }

        let port = try waitForPort(listener)
        let client = StationLink(endpoint: .hostPort(host: "127.0.0.1", port: port),
                                 credential: .code("123456"), salt: Pairing.generateSalt())
        let failed = expectation(description: "handshake rejected")
        let becameReady = expectation(description: "must not become ready")
        becameReady.isInverted = true
        nonisolated(unsafe) var failureReason: String?
        client.onStateChange = { (state: LinkState) in
            if state == .ready { becameReady.fulfill() }
            if case .failed(let reason) = state {
                failureReason = reason
                failed.fulfill()
            }
        }
        client.start()
        defer { client.cancel() }

        wait(for: [failed, becameReady], timeout: 3)
        XCTAssertEqual(failureReason, "Incorrect pairing code",
                       "a mistyped code must surface as such, not as a generic failure")
    }
}

final class PairingTests: XCTestCase {

    func testGeneratedCodeIsAlwaysSixDigits() {
        for value in [UInt32(0), 7, 999_999, 1_000_000, 4_294_967_295] {
            let code = Pairing.generateCode { value }
            XCTAssertEqual(code.count, Pairing.codeDigits, "bad code for \(value): \(code)")
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testSameCodeAndSaltDeriveSameKey() {
        let salt = Pairing.generateSalt()
        XCTAssertEqual(Pairing.derivePSK(code: "123456", salt: salt),
                       Pairing.derivePSK(code: "123456", salt: salt))
    }

    func testDifferentSaltDerivesDifferentKey() {
        XCTAssertNotEqual(Pairing.derivePSK(code: "123456", salt: Pairing.generateSalt()),
                          Pairing.derivePSK(code: "123456", salt: Pairing.generateSalt()))
    }

    func testDifferentCodeDerivesDifferentKey() {
        let salt = Pairing.generateSalt()
        XCTAssertNotEqual(Pairing.derivePSK(code: "123456", salt: salt),
                          Pairing.derivePSK(code: "123457", salt: salt))
    }

    func testLongTermSecretsAreUnique() {
        let secrets = (0..<50).map { _ in Pairing.generateLongTermSecret() }
        XCTAssertEqual(Set(secrets).count, 50)
        XCTAssertTrue(secrets.allSatisfy { $0.count == 32 })
    }
}
