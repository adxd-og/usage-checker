import Foundation
import Security

/// Claude Code's OAuth credentials as Omelette last read them, for this run of the app only.
///
/// Reading Claude Code's item costs a keychain call or a `/usr/bin/security` run, so a poll
/// reads it once and reuses it until it is about to expire. Memory only: since spec
/// 2026-10-25 § Package 2 (ruling 1a, 2026-10-27) Omelette stores no copy of a Claude token
/// anywhere — Anthropic's terms forbid collecting or storing one. The keychain item 3.2 and
/// earlier kept is removed once at launch (`removeLegacyItem`).
///
/// Omelette never refreshes the token: Claude Code rotates its refresh token, and renewal is
/// Claude Code's own (`ClaudeRenewalProbe`).
final class ClaudeCredentialsCache: @unchecked Sendable {
    static let shared = ClaudeCredentialsCache()

    private let lock = NSLock()
    private var stored: ClaudeCredentials.OAuth?

    func load() -> ClaudeCredentials.OAuth? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ oauth: ClaudeCredentials.OAuth) {
        lock.lock()
        defer { lock.unlock() }
        stored = oauth
    }

    // MARK: - The keychain item 3.2 and earlier kept

    /// Omelette's own keychain item through 3.2, which held Claude Code's access AND refresh
    /// token. Named here only to be removed.
    static let legacyService = "com.usagetracker.app.claude-oauth-cache"
    static let legacyAccount = "claude-oauth"
    /// Set once the item is gone, so later launches do not ask again.
    static let legacyItemRemovedKey = "claudeOAuthCacheItemRemoved"

    enum LegacyRemoval: Equatable, Sendable {
        /// An earlier launch removed it; nothing was asked.
        case alreadyDone
        /// The login keychain is locked, or its state unknown: a delete would raise its
        /// password panel. A later launch tries.
        case deferred
        /// Deleted now, or not there at all.
        case done
        /// The keychain refused (an item an older build made, which this one may not
        /// touch); a later launch tries again, as silently.
        case failed(OSStatus)
    }

    /// The rule (ruling 1a): ask once, never while the keychain is not certainly unlocked,
    /// and count an item that is not there as removed.
    static func removeLegacyItem(
        alreadyDone: Bool,
        keychainUnlocked: Bool,
        delete: () -> OSStatus
    ) -> LegacyRemoval {
        if alreadyDone { return .alreadyDone }
        guard keychainUnlocked else { return .deferred }
        let status = delete()
        switch status {
        case errSecSuccess, errSecItemNotFound: return .done
        default: return .failed(status)
        }
    }

    /// The real delete, with keychain UI switched off: never a dialog at launch.
    static func deleteLegacyItem() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
        ]
        return KeychainNoUI.withoutUI { SecItemDelete(query as CFDictionary) }
    }
}
