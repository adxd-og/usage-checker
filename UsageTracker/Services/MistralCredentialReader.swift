import Foundation

/// Where Brioche finds the Mistral API key the vibe CLI uses (spec 2026-11-10 Mistral provider
/// § Credential), in vibe's own order: a `MISTRAL_API_KEY=` line in `~/.vibe/.env`, then vibe's
/// keychain item through `/usr/bin/security`. With a key in both, vibe runs on the file's, and
/// Brioche has to show that key's budget. The keychain read and the file are injected, so a
/// test never touches the real keychain or home. The key goes nowhere but the `Authorization`
/// header of the billing requests: nothing here logs it.
struct MistralCredentialReader: Sendable {
    /// vibe's keychain item, never with a dialog; nil when there is no answer.
    var keychain: @Sendable () -> String?
    /// `~/.vibe/.env`.
    var envFileURL: URL

    static let envKey = "MISTRAL_API_KEY"

    static let live = MistralCredentialReader(
        keychain: { MistralKeychain.readViaSecurityTool() },
        envFileURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe/.env")
    )

    /// The key, the file's first; nil when neither has one, an OIDC-only sign-in included.
    /// The keychain is not asked while the file holds a key.
    func read() -> String? {
        if let text = try? String(contentsOf: envFileURL, encoding: .utf8),
           let key = Self.key(fromEnvFile: text) {
            return key
        }
        return keychain().flatMap(Self.cleaned)
    }

    /// `security -w`'s stdout: the secret and a newline.
    static func key(fromSecurityOutput data: Data) -> String? {
        String(data: data, encoding: .utf8).flatMap(cleaned)
    }

    /// The last `MISTRAL_API_KEY` line's value in a dotenv file. Tolerated: LF, CR or CRLF
    /// line ends, `export ` in front, spaces around `=`, single or double quotes, a ` #`
    /// comment after an unquoted value. A commented-out line and another key are not this one;
    /// an empty value is no key.
    static func key(fromEnvFile text: String) -> String? {
        var found: String?
        // `Character.isNewline`: "\r\n" is one Character, so splitting on "\n" alone misses it.
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            // python-dotenv, which vibe reads the file with: `export` and any blanks after it.
            if line.hasPrefix("export"), let blank = line.dropFirst("export".count).first,
               blank == " " || blank == "\t" {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == envKey
            else { continue }
            found = value(String(line[line.index(after: equals)...]))
        }
        return found.flatMap(cleaned)
    }

    /// What follows `=`: inside matching quotes, or up to a ` #` comment.
    private static func value(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            let rest = value.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return String(rest) }
            return String(rest[..<end])
        }
        // python-dotenv drops `\s+#…` from an unquoted value: a tab before `#` counts too.
        if let comment = value.range(of: #"[ \t]+#"#, options: .regularExpression) {
            return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// vibe's keychain item (`vibe/utils/keyring.py`): a generic password vibe writes and reads
/// through `/usr/bin/security`, so the tool is on its access list and Brioche borrows that
/// access, as it does for Claude Code's item (`ClaudeKeychainReader.readViaSecurityToolResult`).
enum MistralKeychain {
    static let service = "ai.mistral.vibe"
    static let account = "MISTRAL_API_KEY"

    /// The key, never with a dialog: nothing is run unless the login keychain is certainly
    /// unlocked and the item's access list names the tool, the two preflights Claude's delegated
    /// read makes. A refused read is no key: Mistral then reads as not signed in.
    static func readViaSecurityTool() -> String? {
        guard KeychainNoUI.isDefaultKeychainCertainlyUnlocked,
              KeychainNoUI.aclTrusts(path: ClaudeKeychainReader.securityToolPath, service: service, account: account),
              let data = ClaudeKeychainReader.runSecurityTool(service: service, account: account)
        else { return nil }
        return MistralCredentialReader.key(fromSecurityOutput: data)
    }
}
