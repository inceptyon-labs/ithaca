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

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
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
