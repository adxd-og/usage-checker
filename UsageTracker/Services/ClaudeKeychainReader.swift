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

/// Two readings of Claude Code's sign-in compare field by field: the resolution and the
/// renewal rules ask whether one is the other.
extension ClaudeCredentials.OAuth: Equatable {}

enum ClaudeKeychainError: LocalizedError, Sendable {
    case notFound
    case readFailed(OSStatus)
    case decodeFailed(String)
    /// Reading would show a permission prompt (non-interactive probe declined).
    case interactionRequired

    var errorDescription: String? {
        switch self {
        case .notFound: return ClaudeSignInCopy.notFoundMessage
        case .readFailed(let s): return "Keychain read failed (status \(s))"
        case .decodeFailed(let m): return "Could not parse credentials: \(m)"
        case .interactionRequired: return ClaudeSignInCopy.deniedMessage
        }
    }
}

/// What one of Claude Code's credential sources answered (spec 2026-10-25 § Design › Package 2,
/// Sign in). Why a signed-out Claude is signed out comes from here, where the read and decode
/// errors used to be swallowed.
enum ClaudeSourceRead: Equatable, Sendable {
    case found(ClaudeCredentials.OAuth)
    /// No such item.
    case absent
    /// The item is there, but reading it needs a permission Omelette does not have silently:
    /// its access list, or a locked keychain.
    case refused
    /// The item is there and could not be read or decoded; the read's own words.
    case unreadable(String)

    /// The item as the provider reads it: the direct silent read, and when that was refused
    /// or failed, the same item through `/usr/bin/security`, whose access survives this app's
    /// renames. An absent item is not asked for twice.
    static func combining(direct: ClaudeSourceRead, security: () -> ClaudeSourceRead) -> ClaudeSourceRead {
        switch direct {
        case .found, .absent:
            return direct
        case .refused, .unreadable:
            switch security() {
            case .found(let oauth): return .found(oauth)
            case .unreadable(let words): return .unreadable(words)
            case .absent, .refused: return direct
            }
        }
    }
}

/// Where the provider reads Claude Code's sign-in, as closures, so a test hands in its own.
struct ClaudeCredentialSources: Sendable {
    /// `~/.claude/.credentials.json`; nil when absent or not decodable.
    var file: @Sendable () -> ClaudeCredentials.OAuth?
    /// Claude Code's keychain item, never with a dialog.
    var item: @Sendable () -> ClaudeSourceRead
    /// The renewal guard's read (ruling 2b): the item through `/usr/bin/security` alone, the
    /// tool Claude Code reads it with.
    var itemViaSecurityTool: @Sendable () -> ClaudeSourceRead
    /// The renewal guard's lock check: unlocked for certain; a state that cannot be read counts
    /// as locked.
    var keychainUnlocked: @Sendable () -> Bool

    static let live = ClaudeCredentialSources(
        file: { ClaudeKeychainReader.readFromFile()?.claudeAiOauth },
        item: { ClaudeKeychainReader.readItemSilently() },
        itemViaSecurityTool: { ClaudeKeychainReader.readViaSecurityToolResult() },
        keychainUnlocked: { KeychainNoUI.isDefaultKeychainCertainlyUnlocked }
    )
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
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            // Non-interactive, these mean "the ACL would have needed your approval".
            // Interactive, they mean the user saw the dialog and said no — Deny comes
            // back as errSecAuthFailed and the close box as errSecUserCanceled (-128).
            // Both used to fall through to `.readFailed`, so the Settings button
            // answered a deliberate refusal with "Keychain read failed (status -128)".
            // The situation is the same either way: we need permission we don't have.
            throw ClaudeKeychainError.interactionRequired
        default:
            throw ClaudeKeychainError.readFailed(status)
        }
    }

    /// Claude Code's item as the provider reads it: never a dialog, and an answer that says
    /// why when there is nothing usable (spec 2026-10-25 § Package 2).
    static func readItemSilently() -> ClaudeSourceRead {
        ClaudeSourceRead.combining(direct: directRead(), security: { readViaSecurityToolResult() })
    }

    /// This binary's own silent read, its errors kept apart instead of swallowed.
    private static func directRead() -> ClaudeSourceRead {
        do {
            return .found(try readNonInteractive().claudeAiOauth)
        } catch ClaudeKeychainError.notFound {
            return .absent
        } catch ClaudeKeychainError.interactionRequired {
            return .refused
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// The tool Claude Code writes its credential item with — and therefore a name the
    /// item's ACL trusts, whatever this app happens to be called this month.
    static let securityToolPath = "/usr/bin/security"

    /// Silent read delegated to `/usr/bin/security`.
    ///
    /// A keychain ACL trusts *binaries*, by path and signature. Renaming or re-signing
    /// this app drops it out of `Claude Code-credentials`' trust list, and from then on
    /// its own silent read can only return `errSecAuthFailed` — the prompt is suppressed
    /// by design, so nothing is left to read from and the menu bar goes signed-out roughly
    /// every time the access token expires.
    ///
    /// `security` is in that trust list because Claude Code writes the item through it,
    /// so borrowing its access gets the current credentials with no panel and no ACL
    /// surgery. Verified on this item: a direct silent read answers -25293 while the
    /// delegated one returns the payload. It is also the read Claude Code itself makes, so
    /// its answer is the renewal guard's (ruling 2b): a locked keychain or an access list
    /// without `security` is `.refused`, and nothing is run.
    static func readViaSecurityToolResult(for service: String = ClaudeKeychainReader.service) -> ClaudeSourceRead {
        // Locked keychain: `security` would raise a password panel this process can't
        // suppress, and it has no no-UI policy of its own, so "could not tell" counts as
        // locked too (KeychainNoUI.swift:83) — stricter than the direct read above.
        guard KeychainNoUI.isDefaultKeychainCertainlyUnlocked else { return .refused }
        // And only when the ACL really names the tool. Without this check a changed
        // Claude Code storage backend would turn a background poll into a dialog.
        guard KeychainNoUI.aclTrusts(path: securityToolPath, service: service) else { return .refused }
        guard let data = runSecurityTool(service: service) else { return .refused }
        do {
            return .found(try JSONDecoder().decode(ClaudeCredentials.self, from: data).claudeAiOauth)
        } catch {
            return .unreadable(ClaudeKeychainError.decodeFailed(String(describing: error)).localizedDescription)
        }
    }

    /// The delegated read's credentials alone; nil for any other answer.
    static func readViaSecurityTool(for service: String = ClaudeKeychainReader.service) -> ClaudeCredentials? {
        guard case .found(let oauth) = readViaSecurityToolResult(for: service) else { return nil }
        return ClaudeCredentials(claudeAiOauth: oauth)
    }

    /// Runs `security find-generic-password -w` and returns its stdout.
    ///
    /// The timeout is the backstop for the preflight above: if the tool ever does end up
    /// facing a panel, it would sit there until the user answered, holding a poll open.
    /// Killing it takes the request down with it.
    private static func runSecurityTool(service: String, timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityToolPath)
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: waiting on a process whose pipe is full deadlocks.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
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
