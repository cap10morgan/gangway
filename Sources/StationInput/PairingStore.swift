import Foundation
import Security
import StationKit

/// Persists the long-term secret established with each paired Mac.
///
/// Keychain rather than UserDefaults: this secret is equivalent to a password for
/// injecting input into the paired machine, so it must not sit in a world-readable
/// plist. Items are marked `ThisDeviceOnly` so they are never carried to another Mac
/// by an iCloud Keychain sync or a migration.
public enum PairingStore {

    private static let service = "com.station.pairing"

    public struct Peer: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var edge: ScreenEdge
        public init(id: UUID, name: String, edge: ScreenEdge) {
            self.id = id
            self.name = name
            self.edge = edge
        }
    }

    // MARK: - Secrets

    public static func saveSecret(_ secret: Data, for peer: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peer.uuidString,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    public static func secret(for peer: UUID) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peer.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public static func removeSecret(for peer: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peer.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
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

    // MARK: - Peer list

    /// Peer metadata is not secret, so it lives in UserDefaults; only the secret is in
    /// the Keychain. Removing a peer clears both.
    private static let peersKey = "com.station.peers"

    public static func peers() -> [Peer] {
        guard let data = UserDefaults.standard.data(forKey: peersKey),
              let peers = try? JSONDecoder().decode([Peer].self, from: data) else { return [] }
        return peers
    }

    public static func upsert(_ peer: Peer) {
        var all = peers().filter { $0.id != peer.id }
        all.append(peer)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: peersKey)
        }
    }

    public static func remove(_ peerID: UUID) {
        let remaining = peers().filter { $0.id != peerID }
        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: peersKey)
        }
        removeSecret(for: peerID)
    }
}
