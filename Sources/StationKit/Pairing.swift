import Foundation
import CryptoKit

/// Pairing and key derivation.
///
/// Station authenticates peers with a TLS 1.3 pre-shared key rather than
/// certificates. A short code shown on the primary is stretched into the PSK, so the
/// first connection is mutually authenticated with no certificate generation, no
/// trust-on-first-use window, and no fingerprint for a user to eyeball.
///
/// After a successful pairing the peers swap a full-entropy long-term secret and use
/// that for every subsequent connection, so the short code is never reusable.
public enum Pairing {
    /// Digits in a human-entered pairing code. Six digits is only ~20 bits, which is
    /// safe here because the code is single-use, short-lived, and an online-only
    /// guess: TLS-PSK gives an attacker no offline verifier to grind against.
    public static let codeDigits = 6

    public static func generateCode(using generator: () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }) -> String {
        String(format: "%0\(codeDigits)u", generator() % 1_000_000)
    }

    public static func generateLongTermSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Domain separation string. Bumping this invalidates every existing pairing,
    /// which is the desired behaviour if the handshake ever changes.
    private static let info = Data("station-psk-v1".utf8)

    /// Stretch a short pairing code into a PSK.
    ///
    /// `salt` must be a per-session random value supplied by the primary and sent in
    /// the clear, so that two pairings using the same code never derive the same key.
    public static func derivePSK(code: String, salt: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Derive the session PSK from an established long-term secret.
    public static func derivePSK(longTermSecret: Data, salt: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: longTermSecret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

/// What a peer proves it knows in order to connect.
public enum PairingCredential: Sendable {
    /// First contact: the user typed the code shown on the other Mac.
    case code(String)
    /// An established pairing.
    case longTerm(Data)

    public func psk(salt: Data) -> Data {
        switch self {
        case .code(let code):     return Pairing.derivePSK(code: code, salt: salt)
        case .longTerm(let data): return Pairing.derivePSK(longTermSecret: data, salt: salt)
        }
    }
}
