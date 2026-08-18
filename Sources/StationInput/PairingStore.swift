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

    // MARK: - This Mac's identity

    /// Load the long-term identity, creating and storing one on first run.
    public static func loadOrCreateIdentity() throws -> Identity {
        if let existing = try? loadIdentity() { return existing }
        let identity = Identity.generate()
        try save(identity)
        return identity
    }

    public static func loadIdentity() throws -> Identity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.keychain(status)
        }
        return try Identity(rawPrivateKey: data)
    }

    public static func save(_ identity: Identity) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = identity.rawPrivateKey
        // ThisDeviceOnly: an identity that followed a Time Machine restore to another
        // Mac would let that Mac impersonate this one to every paired peer.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
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
