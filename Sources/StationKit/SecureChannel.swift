import Foundation
import CryptoKit

/// Station's pairing and session handshake.
///
/// ## Why not a shared six-digit code
///
/// The previous design derived a TLS-PSK from a typed six-digit code. TLS 1.3 PSK sends
/// a *binder*, an HMAC over the handshake transcript keyed by the PSK, so anyone
/// passively recording one pairing could brute-force a 10^6 keyspace offline in seconds
/// and recover both the PSK and the long-term secret exchanged afterwards. A salt does
/// not help: it only prevents precomputation shared across pairings, not guessing.
///
/// Any scheme where a low-entropy secret produces a value an observer can check offline
/// has this flaw. The fix is to remove the low-entropy secret entirely.
///
/// ## The design
///
/// 1. Both sides exchange ephemeral X25519 public keys in the clear and derive a shared
///    secret. A passive observer cannot compute it, so there is nothing to brute-force.
/// 2. Both derive a six-digit Short Authentication String from the transcript. An
///    active machine-in-the-middle must run two separate exchanges, which produce two
///    different transcripts and therefore two different SAS values, so the user sees a
///    mismatch. The SAS is a *comparison*, never a secret, and is worthless to an
///    attacker who records it.
/// 3. Inside the encrypted channel each side sends its long-term Ed25519 identity and a
///    signature over the transcript. On first pairing the user confirms the SAS matches
///    and the peer identity is pinned; afterwards the pinned key authenticates
///    automatically and no user action is needed.
///
/// Passive attacker: defeated by Diffie-Hellman. Active attacker at pairing: defeated by
/// the SAS comparison. Active attacker afterwards: defeated by the pinned identity.
public enum SecureChannel {
    static let protocolLabel = Data("station-channel-v2".utf8)
    public static let sasDigits = 6
}

public enum HandshakeRole: Sendable {
    case initiator   // the primary, which dials
    case responder   // the secondary, which listens
}

public enum HandshakeError: Error, Equatable, LocalizedError {
    case malformedMessage
    case badSignature
    case unknownPeer
    case peerIdentityChanged
    case wrongState

    public var errorDescription: String? {
        switch self {
        case .malformedMessage:    return "The other Mac sent something Station could not read."
        case .badSignature:        return "The other Mac failed to prove its identity."
        case .unknownPeer:         return "This Mac has not been paired yet."
        case .peerIdentityChanged:
            return "This Mac's identity has changed since you paired with it. "
                 + "That can mean Station was reinstalled there, or that something is "
                 + "impersonating it. Remove the pairing and pair again if you expected this."
        case .wrongState:          return "Handshake steps arrived out of order."
        }
    }
}

/// A long-term identity for this Mac. The private key never leaves the Keychain.
public struct Identity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public static func generate() -> Identity {
        Identity(privateKey: Curve25519.Signing.PrivateKey())
    }

    public init(rawPrivateKey: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public var rawPrivateKey: Data { privateKey.rawRepresentation }
}

/// Directional keys for the encrypted session, plus what the user must verify.
public struct HandshakeOutcome: Sendable {
    public let sendKey: SymmetricKey
    public let receiveKey: SymmetricKey
    /// Six digits both Macs display. Equal values mean no machine-in-the-middle.
    public let sas: String
    /// The peer's long-term public key, to pin on first pairing.
    public let peerIdentity: Data
    /// True when the peer's identity matched a previously pinned key.
    public let wasAlreadyKnown: Bool
}

/// Drives the handshake for one connection.
///
/// Message flow, with the initiator on the left:
///
///     -> ephemeral public key                       (32 bytes, clear)
///     <- ephemeral public key                       (32 bytes, clear)
///        both derive shared secret, session keys, and SAS
///     -> sealed(identity public key || signature)
///     <- sealed(identity public key || signature)
///
/// Signatures cover the transcript hash, which binds both ephemeral keys, so a replayed
/// signature from another session will not verify.
public final class Handshake {

    private enum State {
        case start
        case awaitingPeerEphemeral
        case awaitingPeerIdentity
        case complete
    }

    private let role: HandshakeRole
    private let identity: Identity
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    /// Pinned key from a previous pairing, if any.
    private let expectedPeerIdentity: Data?

    private var state: State = .start
    private var peerEphemeral: Data?
    private var transcriptHash: Data?
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sas: String?

    public init(role: HandshakeRole, identity: Identity, expectedPeerIdentity: Data? = nil) {
        self.role = role
        self.identity = identity
        self.expectedPeerIdentity = expectedPeerIdentity
        self.ephemeral = Curve25519.KeyAgreement.PrivateKey()
    }

    // MARK: - Step 1: ephemeral exchange

    /// Our ephemeral public key. Idempotent: the initiator sends this first, while the
    /// responder sends it after receiving the initiator's, so the two roles call this
    /// at different points in the exchange.
    public func ephemeralMessage() -> Data {
        if state == .start { state = .awaitingPeerEphemeral }
        return ephemeral.publicKey.rawRepresentation
    }

    /// Consume the peer's ephemeral key and derive session keys and the SAS.
    public func receiveEphemeral(_ data: Data) throws {
        guard state == .start || state == .awaitingPeerEphemeral else {
            throw HandshakeError.wrongState
        }
        guard data.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) else {
            throw HandshakeError.malformedMessage
        }
        peerEphemeral = data

        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey)

        // Transcript ordering must be identical on both sides, so order by role rather
        // than by arrival: the initiator's key always comes first.
        let mine = ephemeral.publicKey.rawRepresentation
        let ordered = role == .initiator ? mine + data : data + mine
        let hash = Data(SHA256.hash(data: SecureChannel.protocolLabel + ordered))
        transcriptHash = hash

        // Separate keys per direction so the two streams can never be confused, and a
        // reflected message cannot be decrypted by its own sender.
        let initiatorToResponder = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: hash,
            sharedInfo: Data("i2r".utf8), outputByteCount: 32)
        let responderToInitiator = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: hash,
            sharedInfo: Data("r2i".utf8), outputByteCount: 32)

        switch role {
        case .initiator:
            sendKey = initiatorToResponder
            receiveKey = responderToInitiator
        case .responder:
            sendKey = responderToInitiator
            receiveKey = initiatorToResponder
        }

        let sasKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: hash,
            sharedInfo: Data("sas".utf8), outputByteCount: 32)
        sas = Self.digits(from: sasKey, count: SecureChannel.sasDigits)

        state = .awaitingPeerIdentity
    }

    // MARK: - Step 2: identity exchange

    /// Our identity and proof, sealed to the peer.
    public func identityMessage() throws -> Data {
        guard state == .awaitingPeerIdentity,
              let hash = transcriptHash, let sendKey else { throw HandshakeError.wrongState }
        let signature = try identity.privateKey.signature(for: hash)
        var payload = Data()
        payload.append(identity.publicKeyData)   // 32 bytes
        payload.append(signature)                // 64 bytes
        return try ChaChaPoly.seal(payload, using: sendKey, nonce: Self.nonce(0)).combined
    }

    /// Verify the peer's identity and finish.
    public func receiveIdentity(_ data: Data) throws -> HandshakeOutcome {
        guard state == .awaitingPeerIdentity,
              let hash = transcriptHash,
              let receiveKey, let sendKey, let sas else { throw HandshakeError.wrongState }

        guard let box = try? ChaChaPoly.SealedBox(combined: data),
              let payload = try? ChaChaPoly.open(box, using: receiveKey),
              payload.count == 96 else {
            throw HandshakeError.malformedMessage
        }
        let peerPublicKeyData = payload.prefix(32)
        let signature = payload.suffix(64)

        guard let peerKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: peerPublicKeyData),
              peerKey.isValidSignature(signature, for: hash) else {
            throw HandshakeError.badSignature
        }

        // A pinned identity that no longer matches is a hard failure, not a prompt to
        // re-pair: it is exactly what an impersonating peer looks like.
        var known = false
        if let expected = expectedPeerIdentity {
            guard expected == Data(peerPublicKeyData) else {
                throw HandshakeError.peerIdentityChanged
            }
            known = true
        }

        state = .complete
        return HandshakeOutcome(sendKey: sendKey,
                                receiveKey: receiveKey,
                                sas: sas,
                                peerIdentity: Data(peerPublicKeyData),
                                wasAlreadyKnown: known)
    }

    // MARK: - Helpers

    /// Fixed nonce is safe here: each handshake key is used for exactly one message.
    /// Transport messages use `CipherState`, which has its own counter.
    /// Inverse of `nonce(_:)`.
    static func counter(from nonce: ChaChaPoly.Nonce) -> UInt64 {
        let bytes = Data(nonce)
        guard bytes.count == 12 else { return 0 }
        return bytes[bytes.startIndex + 4..<bytes.startIndex + 12]
            .withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 12)
        withUnsafeBytes(of: counter.littleEndian) { raw in
            bytes.replaceSubrange(4..<12, with: raw)
        }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Derive the SAS by reducing key material modulo 10^digits. Taking 8 bytes keeps
    /// the modulo bias far below anything observable at six digits.
    static func digits(from key: SymmetricKey, count: Int) -> String {
        let bytes = key.withUnsafeBytes { Data($0) }
        var value: UInt64 = 0
        for byte in bytes.prefix(8) { value = (value << 8) | UInt64(byte) }
        var modulus: UInt64 = 1
        for _ in 0..<count { modulus *= 10 }
        return String(format: "%0\(count)llu", value % modulus)
    }
}

/// Encrypts and decrypts transport frames after the handshake.
///
/// Nonces come from a counter, never repeated for a given key, and the counter is
/// checked on receive so a replayed or reordered frame is rejected rather than
/// delivered as fresh input.
public final class CipherState: @unchecked Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private let lock = NSLock()

    public init(key: SymmetricKey) {
        self.key = key
    }

    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        let n = counter
        counter += 1
        lock.unlock()
        // The counter lives in the nonce, which is authenticated as part of the sealed
        // box. Sending it alongside instead would let an attacker alter the counter we
        // read without invalidating the ciphertext.
        return try ChaChaPoly.seal(plaintext, using: key, nonce: Handshake.nonce(n)).combined
    }

    public enum OpenError: Error, Equatable {
        case malformed
        /// Counter did not advance: a replay, or frames arriving out of order.
        case replay(UInt64)
        case authenticationFailed
    }

    public func open(_ data: Data) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: data) else {
            throw OpenError.malformed
        }
        let n = Handshake.counter(from: box.nonce)

        lock.lock()
        let expected = counter
        lock.unlock()
        guard n >= expected else { throw OpenError.replay(n) }

        guard let plaintext = try? ChaChaPoly.open(box, using: key) else {
            throw OpenError.authenticationFailed
        }
        lock.lock()
        counter = n + 1
        lock.unlock()
        return plaintext
    }
}
