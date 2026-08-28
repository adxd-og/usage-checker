import Foundation
import Security

/// App-owned keychain cache for Claude OAuth credentials.
///
/// Reading Claude Code's own item (`Claude Code-credentials`) can raise a macOS permission
/// dialog whenever that item's access list no longer trusts this binary — a reinstall, a
/// re-signed or renamed build, a fresh login. Keeping our own copy means the menu bar keeps
/// working across those gaps: reading an item we created never prompts.
///
/// We never refresh the token from here. Claude Code rotates its refresh token, so a refresh
/// of our own would invalidate the CLI's session (or lose the race and invalidate ours). This
/// holds whatever Claude Code last exposed, and is replaced when it exposes something newer.
enum ClaudeCredentialsCache {
    static let service = "com.usagetracker.app.claude-oauth-cache"
    static let account = "claude-oauth"

    static func load() -> ClaudeCredentials? {
        // Ours or not, a secret in a locked keychain can't be read without a password
        // panel. Report "no credentials" and let the UI go stale instead.
        guard KeychainNoUI.isDefaultKeychainUnlocked else { return nil }
        var item: AnyObject?
        // Strictly non-interactive: after the app binary is renamed (Usage Checker →
        // Omelette) the old item's ACL doesn't trust the new binary, and a plain read
        // would throw a pointless permission dialog for our OWN cache. Fail silently
        // instead — the bootstrap chain re-acquires credentials and save() below
        // replaces the stale item with one the new binary owns.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUI.apply(to: &query)
        let q = query
        guard KeychainNoUI.withoutUI({ SecItemCopyMatching(q as CFDictionary, &item) }) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
        else { return nil }
        return creds
    }

    /// Stores credentials in the same JSON shape Claude Code uses, so load() reuses
    /// the `ClaudeCredentials` decoder.
    static func save(_ oauth: ClaudeCredentials.OAuth) {
        // A locked login keychain answers a WRITE with the same password panel a read
        // would raise, and no query flag suppresses it — so don't ask. `load()` was
        // gated for that reason; `save()` wasn't, which meant a machine with a locked
        // keychain and a `~/.claude/.credentials.json` present raised the panel from a
        // background poll: the file read succeeded and its result was written here.
        //
        // The guard also keeps the `errSecAuthFailed` branch below honest. While the
        // keychain is locked that status means "locked", not "the item belongs to an
        // older build" — and the delete-and-replace it triggers would throw away the
        // only cached copy on a machine that has no credentials file.
        guard KeychainNoUI.isDefaultKeychainUnlocked else { return }
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
        // Writing our own item can hit the same ACL wall as reading it (a re-signed
        // build), and that must not surface a dialog from a poll either.
        let status = KeychainNoUI.withoutUI {
            SecItemUpdate(base as CFDictionary, update as CFDictionary)
        }
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            addFresh(base: base, data: data)
        case errSecAuthFailed, errSecInteractionNotAllowed:
            // The item belongs to a previous binary (pre-rename install) and its ACL
            // doesn't trust us. Replace it with one we own — self-healing migration.
            _ = KeychainNoUI.withoutUI { SecItemDelete(base as CFDictionary) }
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
        let attrs = add
        _ = KeychainNoUI.withoutUI { SecItemAdd(attrs as CFDictionary, nil) }
    }

    static func clear() {
        // Same reason as save(): a delete is a write, and a write to a locked keychain
        // prompts. Leaving the stale item behind is harmless — the next unlocked save
        // replaces it.
        guard KeychainNoUI.isDefaultKeychainUnlocked else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
