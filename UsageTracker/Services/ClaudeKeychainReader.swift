import Foundation
import Security

struct ClaudeCredentials: Decodable, Sendable {
    struct OAuth: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double
        let scopes: [String]?
        let subscriptionType: String?
        let rateLimitTier: String?
    }
    let claudeAiOauth: OAuth

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth
    }
}

enum ClaudeKeychainError: LocalizedError, Sendable {
    case notFound
    case readFailed(OSStatus)
    case decodeFailed(String)
    /// Reading would show a permission prompt (non-interactive probe declined).
    case interactionRequired

    var errorDescription: String? {
        switch self {
        case .notFound: return "Claude Code credentials not found. Please log into Claude Code (run `claude login`)."
        case .readFailed(let s): return "Keychain read failed (status \(s))"
        case .decodeFailed(let m): return "Could not parse credentials: \(m)"
        case .interactionRequired: return "Keychain access needs your permission"
        }
    }
}

enum ClaudeKeychainReader {
    static let service = "Claude Code-credentials"

    /// Interactive read — may show the macOS keychain permission prompt.
    static func read() throws -> ClaudeCredentials {
        try read(allowingUI: true)
    }

    /// Background probe — never shows a prompt. Throws `.interactionRequired` when the
    /// item's ACL would need user approval (e.g. after Claude Code re-created it).
    static func readNonInteractive() throws -> ClaudeCredentials {
        try read(allowingUI: false)
    }

    private static func read(allowingUI: Bool) throws -> ClaudeCredentials {
        // A locked login keychain turns any read of a secret into a password panel that
        // no query flag suppresses. Don't ask; report that interaction would be needed.
        if !allowingUI, !KeychainNoUI.isDefaultKeychainUnlocked {
            throw ClaudeKeychainError.interactionRequired
        }
        var item: AnyObject?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowingUI {
            KeychainNoUI.apply(to: &query)
        }
        let q = query
        let status = allowingUI
            ? KeychainNoUI.withUI { SecItemCopyMatching(q as CFDictionary, &item) }
            : KeychainNoUI.withoutUI { SecItemCopyMatching(q as CFDictionary, &item) }

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw ClaudeKeychainError.decodeFailed("not Data")
            }
            do {
                let creds = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
                return creds
            } catch {
                throw ClaudeKeychainError.decodeFailed(String(describing: error))
            }
        case errSecItemNotFound:
            throw ClaudeKeychainError.notFound
        case errSecInteractionNotAllowed:
            throw ClaudeKeychainError.interactionRequired
        case errSecAuthFailed where !allowingUI:
            throw ClaudeKeychainError.interactionRequired
        default:
            throw ClaudeKeychainError.readFailed(status)
        }
    }

    /// Silent existence check. Asks for the item's *attributes*, never `kSecReturnData`,
    /// so it reads the keychain's index rather than the protected payload — no ACL
    /// evaluation, no prompt, even when the secret itself is unreadable to us.
    /// Lets the UI tell "Claude Code was never logged in" apart from "we can't read it".
    static func itemExists() -> Bool {
        // Locked: we can't tell, and "false" would wrongly claim Claude Code never
        // logged in. Say the item may be there and let the message stay about access.
        guard KeychainNoUI.isDefaultKeychainUnlocked else { return true }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUI.apply(to: &query)
        var item: AnyObject?
        let q = query
        let status = KeychainNoUI.withoutUI { SecItemCopyMatching(q as CFDictionary, &item) }
        // A guarded item still reports its presence via the interaction statuses.
        return status == errSecSuccess || KeychainNoUI.isInteractionRequired(status)
    }

    /// Claude Code stores credentials in a plain file on some setups (and always on Linux).
    /// Reading it needs no keychain access at all, so it's a free prompt-less source.
    static func readFromFile() -> ClaudeCredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
    }
}
