import Foundation
import Security

/// App-owned keychain cache for Claude OAuth credentials.
///
/// Reading Claude Code's own keychain item (`Claude Code-credentials`) triggers a macOS
/// permission prompt, and "Always Allow" doesn't stick: Claude Code re-creates the item on
/// every token refresh (~8h), which resets its ACL and re-prompts us. So after the first
/// successful read we keep a copy in an item *we* own — reading our own item never prompts —
/// and refresh the access token ourselves via `OAuthRefreshClient`.
enum ClaudeCredentialsCache {
    static let service = "com.usagetracker.app.claude-oauth-cache"
    static let account = "claude-oauth"

    static func load() -> ClaudeCredentials? {
        var item: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
        else { return nil }
        return creds
    }

    /// Stores credentials in the same JSON shape Claude Code uses, so load() reuses
    /// the `ClaudeCredentials` decoder.
    static func save(_ oauth: ClaudeCredentials.OAuth) {
        var inner: [String: Any] = [
            "accessToken": oauth.accessToken,
            "expiresAt": oauth.expiresAt,
        ]
        if let r = oauth.refreshToken { inner["refreshToken"] = r }
        if let s = oauth.scopes { inner["scopes"] = s }
        if let s = oauth.subscriptionType { inner["subscriptionType"] = s }
        if let t = oauth.rateLimitTier { inner["rateLimitTier"] = t }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": inner]) else { return }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
