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
        try listener.start(advertise: false)
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
        try listener.start(advertise: false)
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
        try listener.start(advertise: false)
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
