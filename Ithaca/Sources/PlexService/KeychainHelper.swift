import Foundation
import Security

/// Minimal Keychain wrapper using the Security framework directly.
enum KeychainHelper {
    private static let service = "com.inceptyon.ithaca"
    /// Device-only, so the tokens never travel in a backup to another device.
    private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
    private static let accessibilityMigratedKey = "KeychainThisDeviceOnlyMigrated"

    @discardableResult
    static func save(key: String, data: Data) -> Bool {
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    enum Read {
        case found(Data)
        case missing
        /// The device hasn't been unlocked since it started, so no item can be
        /// read yet. Not the same as no item: nothing may be deleted or
        /// written over because of it.
        case locked
    }

    static func read(key: String) -> Read {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return (result as? Data).map(Read.found) ?? .missing
        case errSecInteractionNotAllowed:
            return .locked
        default:
            return .missing
        }
    }

    static func load(key: String) -> Data? {
        guard case let .found(data) = read(key: key) else { return nil }
        return data
    }

    /// Moves items written by earlier versions (`AfterFirstUnlock`, which a
    /// backup restores onto another device) to the device-only class. Runs once,
    /// at launch; retried next launch if the Keychain is still locked.
    static func migrateAccessibilityIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: accessibilityMigratedKey) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: accessibility,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
        UserDefaults.standard.set(true, forKey: accessibilityMigratedKey)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
