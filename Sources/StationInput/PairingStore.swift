import Foundation
import Security
import StationKit

/// Persists this Mac's long-term identity and the peers it has paired with.
///
/// The private key lives in the Keychain because possession of it lets a peer inject
/// input into this Mac. Peer *public* keys are not secret and live in UserDefaults;
/// they are pinned, so a peer whose key changes is rejected rather than silently
/// re-trusted.
public enum PairingStore {

    private static let service = "com.station.identity"
    private static let identityAccount = "self"
    private static let peersKey = "com.station.pairedPeers"

    /// Base query for the identity item.
    ///
    /// `kSecUseDataProtectionKeychain` is essential, not a preference. Without it the
    /// request goes through the legacy file-based keychain, whose ACL check blocks in
    /// `securityd` waiting for an authorization decision that a command-line process
    /// cannot present. Measured: `stationctl` hung indefinitely inside
    /// `SecKeychainItemCopyContent` before a single line of output. The data protection
    /// keychain has no such prompt and fails fast instead.
    private static func identityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Where the identity lives when the data protection keychain is unavailable, which
    /// is the case for unsigned command-line builds with no keychain access group.
    ///
    /// Weaker than the Keychain: readable by anything running as this user. Acceptable
    /// for a developer CLI, and the app bundle keeps using the Keychain.
    private static var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Station", isDirectory: true)
        return base.appendingPathComponent("identity.key")
    }

    // MARK: - This Mac's identity

    /// Load the long-term identity, creating and storing one on first run.
    public static func loadOrCreateIdentity() throws -> Identity {
        if let existing = try? loadIdentity() { return existing }
        let identity = Identity.generate()
        try save(identity)
        return identity
    }

    public static func loadIdentity() throws -> Identity {
        var query = identityQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try Identity(rawPrivateKey: data)
        }
        if let data = try? Data(contentsOf: fallbackURL) {
            return try Identity(rawPrivateKey: data)
        }
        throw StoreError.keychain(status)
    }

    public static func save(_ identity: Identity) throws {
        SecItemDelete(identityQuery() as CFDictionary)

        var attributes = identityQuery()
        attributes[kSecValueData as String] = identity.rawPrivateKey
        // ThisDeviceOnly: an identity that followed a Time Machine restore to another
        // Mac would let that Mac impersonate this one to every paired peer.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }

        // No keychain access group (unsigned CLI builds), so fall back to a file that
        // only this user can read.
        try saveToFallback(identity)
    }

    private static func saveToFallback(_ identity: Identity) throws {
        let url = fallbackURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try identity.rawPrivateKey.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public enum StoreError: Error, LocalizedError {
        case keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    // MARK: - Paired peers

    public struct Peer: Codable, Sendable, Equatable, Identifiable {
        /// The peer's long-term public key. Pinned; this is the identity.
        public var publicKey: Data
        public var name: String
        public var edge: ScreenEdge
        public var pairedAt: Date

        public var id: String { publicKey.map { String(format: "%02x", $0) }.joined() }
        /// Short form for display, so a user can eyeball which peer this is.
        public var fingerprint: String {
            publicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
        }

        public init(publicKey: Data, name: String, edge: ScreenEdge, pairedAt: Date = Date()) {
            self.publicKey = publicKey
            self.name = name
            self.edge = edge
            self.pairedAt = pairedAt
        }
    }

    public static func peers() -> [Peer] {
        guard let data = UserDefaults.standard.data(forKey: peersKey),
              let peers = try? JSONDecoder().decode([Peer].self, from: data) else { return [] }
        return peers
    }

    public static func peer(withKey key: Data) -> Peer? {
        peers().first { $0.publicKey == key }
    }

    public static func upsert(_ peer: Peer) {
        var all = peers().filter { $0.publicKey != peer.publicKey }
        all.append(peer)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: peersKey)
        }
    }

    public static func remove(publicKey: Data) {
        let remaining = peers().filter { $0.publicKey != publicKey }
        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: peersKey)
        }
    }

    public static func knownPeerKeys() -> [Data] {
        peers().map(\.publicKey)
    }
}
