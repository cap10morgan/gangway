import XCTest
import CryptoKit
@testable import StationKit

final class HandshakeTests: XCTestCase {

    /// Runs a full handshake between two parties and returns both outcomes.
    private func pair(initiator: Handshake, responder: Handshake) throws
        -> (HandshakeOutcome, HandshakeOutcome) {
        let e1 = initiator.ephemeralMessage()
        let e2 = responder.ephemeralMessage()
        try initiator.receiveEphemeral(e2)
        try responder.receiveEphemeral(e1)
        let i1 = try initiator.identityMessage()
        let i2 = try responder.identityMessage()
        let responderOutcome = try responder.receiveIdentity(i1)
        let initiatorOutcome = try initiator.receiveIdentity(i2)
        return (initiatorOutcome, responderOutcome)
    }

    func testBothSidesAgreeOnKeysAndSAS() throws {
        let a = Identity.generate(), b = Identity.generate()
        let (i, r) = try pair(initiator: Handshake(role: .initiator, identity: a),
                              responder: Handshake(role: .responder, identity: b))

        XCTAssertEqual(i.sas, r.sas, "both Macs must show the same code to compare")
        XCTAssertEqual(i.sas.count, SecureChannel.sasDigits)
        XCTAssertTrue(i.sas.allSatisfy(\.isNumber))

        // Directional keys must cross over.
        XCTAssertEqual(i.sendKey, r.receiveKey)
        XCTAssertEqual(i.receiveKey, r.sendKey)
        XCTAssertNotEqual(i.sendKey, i.receiveKey, "directions must not share a key")

        XCTAssertEqual(i.peerIdentity, b.publicKeyData)
        XCTAssertEqual(r.peerIdentity, a.publicKeyData)
        XCTAssertFalse(i.wasAlreadyKnown)
    }

    func testEachHandshakeProducesFreshKeys() throws {
        let a = Identity.generate(), b = Identity.generate()
        let (i1, _) = try pair(initiator: Handshake(role: .initiator, identity: a),
                               responder: Handshake(role: .responder, identity: b))
        let (i2, _) = try pair(initiator: Handshake(role: .initiator, identity: a),
                               responder: Handshake(role: .responder, identity: b))
        XCTAssertNotEqual(i1.sendKey, i2.sendKey, "ephemeral keys must not repeat")
        XCTAssertNotEqual(i1.sas, i2.sas)
    }

    /// The property the whole design exists for: a machine-in-the-middle running two
    /// separate exchanges cannot make both sides show the same SAS.
    func testMachineInTheMiddleProducesMismatchedSAS() throws {
        let alice = Identity.generate(), bob = Identity.generate()
        let mallory = Identity.generate()

        // Mallory talks to Alice as responder and to Bob as initiator.
        let aliceSide = Handshake(role: .initiator, identity: alice)
        let malloryToAlice = Handshake(role: .responder, identity: mallory)
        let malloryToBob = Handshake(role: .initiator, identity: mallory)
        let bobSide = Handshake(role: .responder, identity: bob)

        let (aliceOutcome, _) = try pair(initiator: aliceSide, responder: malloryToAlice)
        let (_, bobOutcome) = try pair(initiator: malloryToBob, responder: bobSide)

        XCTAssertNotEqual(aliceOutcome.sas, bobOutcome.sas,
                          "an interposed attacker must not be able to match both SAS values")
        // And each side sees Mallory's identity, not the peer they intended.
        XCTAssertEqual(aliceOutcome.peerIdentity, mallory.publicKeyData)
        XCTAssertEqual(bobOutcome.peerIdentity, mallory.publicKeyData)
    }

    /// After pairing, a pinned identity authenticates automatically.
    func testPinnedIdentityIsRecognised() throws {
        let a = Identity.generate(), b = Identity.generate()
        let (i, r) = try pair(
            initiator: Handshake(role: .initiator, identity: a,
                                 expectedPeerIdentity: b.publicKeyData),
            responder: Handshake(role: .responder, identity: b,
                                 expectedPeerIdentity: a.publicKeyData))
        XCTAssertTrue(i.wasAlreadyKnown)
        XCTAssertTrue(r.wasAlreadyKnown)
    }

    /// An impostor presenting a different identity must be rejected outright.
    func testPinnedIdentityMismatchIsRejected() throws {
        let a = Identity.generate(), b = Identity.generate(), impostor = Identity.generate()
        let initiator = Handshake(role: .initiator, identity: a,
                                  expectedPeerIdentity: b.publicKeyData)
        let responder = Handshake(role: .responder, identity: impostor)

        let e1 = initiator.ephemeralMessage()
        let e2 = responder.ephemeralMessage()
        try initiator.receiveEphemeral(e2)
        try responder.receiveEphemeral(e1)
        let fromImpostor = try responder.identityMessage()

        XCTAssertThrowsError(try initiator.receiveIdentity(fromImpostor)) { error in
            XCTAssertEqual(error as? HandshakeError, .peerIdentityChanged)
        }
    }

    func testTamperedIdentityMessageIsRejected() throws {
        let a = Identity.generate(), b = Identity.generate()
        let initiator = Handshake(role: .initiator, identity: a)
        let responder = Handshake(role: .responder, identity: b)
        let e1 = initiator.ephemeralMessage()
        let e2 = responder.ephemeralMessage()
        try initiator.receiveEphemeral(e2)
        try responder.receiveEphemeral(e1)

        var message = try responder.identityMessage()
        message[message.count - 1] ^= 0xFF   // flip a bit in the tag

        XCTAssertThrowsError(try initiator.receiveIdentity(message)) { error in
            XCTAssertEqual(error as? HandshakeError, .malformedMessage)
        }
    }

    func testRejectsMalformedEphemeralKey() {
        let handshake = Handshake(role: .initiator, identity: .generate())
        _ = handshake.ephemeralMessage()
        XCTAssertThrowsError(try handshake.receiveEphemeral(Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? HandshakeError, .malformedMessage)
        }
    }

    func testStepsOutOfOrderAreRejected() {
        let handshake = Handshake(role: .initiator, identity: .generate())
        XCTAssertThrowsError(try handshake.identityMessage()) { error in
            XCTAssertEqual(error as? HandshakeError, .wrongState)
        }
    }

    func testIdentityRoundTripsThroughRawBytes() throws {
        let identity = Identity.generate()
        let restored = try Identity(rawPrivateKey: identity.rawPrivateKey)
        XCTAssertEqual(restored.publicKeyData, identity.publicKeyData)
    }
}

final class CipherStateTests: XCTestCase {

    private func channel() -> (CipherState, CipherState) {
        let key = SymmetricKey(size: .bits256)
        return (CipherState(key: key), CipherState(key: key))
    }

    func testRoundTripsMessagesInOrder() throws {
        let (sender, receiver) = channel()
        for i in 0..<50 {
            let payload = Data("message \(i)".utf8)
            XCTAssertEqual(try receiver.open(try sender.seal(payload)), payload)
        }
    }

    /// A captured frame replayed later must not be accepted: it would re-inject input.
    func testRejectsReplayedFrame() throws {
        let (sender, receiver) = channel()
        let first = try sender.seal(Data("click".utf8))
        let second = try sender.seal(Data("click".utf8))
        _ = try receiver.open(first)
        _ = try receiver.open(second)

        XCTAssertThrowsError(try receiver.open(first)) { error in
            guard case CipherState.OpenError.replay = error else {
                return XCTFail("expected a replay rejection, got \(error)")
            }
        }
    }

    func testRejectsTamperedCiphertext() throws {
        let (sender, receiver) = channel()
        var frame = try sender.seal(Data("keystroke".utf8))
        frame[frame.count - 1] ^= 0x01
        XCTAssertThrowsError(try receiver.open(frame)) { error in
            XCTAssertEqual(error as? CipherState.OpenError, .authenticationFailed)
        }
    }

    func testRejectsFrameFromAnotherKey() throws {
        let (sender, _) = channel()
        let (_, foreignReceiver) = channel()
        let frame = try sender.seal(Data("secret".utf8))
        XCTAssertThrowsError(try foreignReceiver.open(frame)) { error in
            XCTAssertEqual(error as? CipherState.OpenError, .authenticationFailed)
        }
    }

    func testRejectsGarbage() {
        let (_, receiver) = channel()
        XCTAssertThrowsError(try receiver.open(Data([0, 1, 2])))
    }

    func testNonceCounterRoundTrips() {
        for value in [UInt64(0), 1, 12345, UInt64.max / 2] {
            XCTAssertEqual(Handshake.counter(from: Handshake.nonce(value)), value)
        }
    }
}
