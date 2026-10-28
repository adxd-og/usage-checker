import Foundation

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
}
