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
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Claude Code credentials not found. Please log into Claude Code (run `claude login`)."
        case .readFailed(let s): return "Keychain read failed (status \(s))"
        case .decodeFailed(let m): return "Could not parse credentials: \(m)"
        case .writeFailed(let s): return "Keychain write failed (status \(s))"
        }
    }
}

enum ClaudeKeychainReader {
    static let service = "Claude Code-credentials"

    static func read() throws -> ClaudeCredentials {
        var item: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
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
        default:
            throw ClaudeKeychainError.readFailed(status)
        }
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
