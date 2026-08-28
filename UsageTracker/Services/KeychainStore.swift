import Foundation
import Security

enum KeychainStore {
    static let service = "com.usagetracker.anthropic-admin"
    static let account = "admin-api-key"

    static func saveAdminKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: "KeychainStore", code: Int(status))
        }
    }

    static func loadAdminKey() -> String? {
        guard KeychainNoUI.isDefaultKeychainUnlocked else { return nil }
        var item: AnyObject?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        // This is our own item, but a locked login keychain would still put an unlock
        // panel on screen from a background poll. Skip the admin card instead.
        KeychainNoUI.apply(to: &query)
        let q = query
        let status = KeychainNoUI.withoutUI { SecItemCopyMatching(q as CFDictionary, &item) }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAdminKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
