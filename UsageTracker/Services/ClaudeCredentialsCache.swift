import Foundation
import LocalAuthentication
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
        // Strictly non-interactive: after the app binary is renamed (Usage Checker →
        // Omelette) the old item's ACL doesn't trust the new binary, and a plain read
        // would throw a pointless permission dialog for our OWN cache. Fail silently
        // instead — the bootstrap chain re-acquires credentials and save() below
        // replaces the stale item with one the new binary owns.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
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
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            addFresh(base: base, data: data)
        case errSecAuthFailed, errSecInteractionNotAllowed:
            // The item belongs to a previous binary (pre-rename install) and its ACL
            // doesn't trust us. Replace it with one we own — self-healing migration.
            SecItemDelete(base as CFDictionary)
            addFresh(base: base, data: data)
        default:
            break
        }
    }

    private static func addFresh(base: [String: Any], data: Data) {
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
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
