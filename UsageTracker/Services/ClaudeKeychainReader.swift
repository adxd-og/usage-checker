import Foundation
import LocalAuthentication
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
    case writeFailed(OSStatus)
    /// Reading would show a permission prompt (non-interactive probe declined).
    case interactionRequired

    var errorDescription: String? {
        switch self {
        case .notFound: return "Claude Code credentials not found. Please log into Claude Code (run `claude login`)."
        case .readFailed(let s): return "Keychain read failed (status \(s))"
        case .decodeFailed(let m): return "Could not parse credentials: \(m)"
        case .writeFailed(let s): return "Keychain write failed (status \(s))"
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
        var item: AnyObject?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !allowingUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemCopyMatching(query as CFDictionary, &item)

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

    /// Claude Code stores credentials in a plain file on some setups (and always on Linux).
    /// Reading it needs no keychain access at all, so it's a free prompt-less source.
    static func readFromFile() -> ClaudeCredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentials.self, from: data)
    }

    static func writeBack(_ payload: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        let attrs: [String: Any] = [
            kSecValueData as String: json,
        ]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status != errSecSuccess {
            throw ClaudeKeychainError.writeFailed(status)
        }
    }
}
