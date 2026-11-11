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
    /// The keychain is not asked while the file holds a key. The file is decoded from its
    /// bytes with `String(decoding:)`: `String(contentsOf:)` and `String(data:encoding:)` drop
    /// a leading byte order mark, which python-dotenv keeps — vibe then sees no
    /// `MISTRAL_API_KEY` on that line, and neither may we. Bytes that are not UTF-8 are no
    /// file at all, as before.
    func read() -> String? {
        if let data = try? Data(contentsOf: envFileURL),
           String(data: data, encoding: .utf8) != nil,
           let key = Self.key(fromEnvFile: String(decoding: data, as: UTF8.self)) {
            return key
        }
        return keychain().flatMap(Self.cleaned)
    }

    /// `security -w`'s stdout: the secret and a newline.
    static func key(fromSecurityOutput data: Data) -> String? {
        String(data: data, encoding: .utf8).flatMap(cleaned)
    }

    /// `MISTRAL_API_KEY` in a dotenv file, as vibe gets it from `dotenv_values`: the last
    /// statement that assigns the name wins, a name with no `=` assigns nothing, and an empty
    /// value is no key. A statement python-dotenv cannot parse assigns nothing either, so an
    /// earlier key stands and with none the keychain is asked. Interpolation of `${…}` is not
    /// followed.
    static func key(fromEnvFile text: String) -> String? {
        var found: String?
        // Scalar by scalar, as Python compares `str`: Swift's `==` is canonical equivalence,
        // under which a Kelvin sign is a `K` and a lookalike name would be the key's.
        for binding in PythonDotenv.bindings(in: text)
        where binding.key.unicodeScalars.elementsEqual(envKey.unicodeScalars) {
            found = binding.value
        }
        return found.flatMap(cleaned)
    }

    /// Trimmed; nil when nothing is left, or when a control character sits inside (a quoted
    /// dotenv value may span lines). No key has one, and this string becomes a request header:
    /// such a value is no key from its source, and the next source is asked.
    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return trimmed
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

/// python-dotenv 1.2.2's parser (`dotenv/parser.py`, `parse_stream`), the one vibe reads
/// `~/.vibe/.env` with, ported statement by statement over Unicode scalars as Python's `str`
/// counts them. A quoted value may span lines; a statement the parser cannot finish assigns
/// nothing and is skipped from where it stopped to the end of that line, as python-dotenv
/// skips it with its "could not parse statement" warning.
private struct PythonDotenv {
    struct Binding {
        let key: String
        /// nil for a name with no `=`.
        let value: String?
    }

    private struct Unparsable: Error {}

    private let text: [Unicode.Scalar]
    private var position = 0

    static func bindings(in text: String) -> [Binding] {
        var parser = PythonDotenv(text: Array(text.unicodeScalars))
        var bindings: [Binding] = []
        while parser.position < parser.text.count {
            if let binding = parser.parseBinding() { bindings.append(binding) }
        }
        return bindings
    }

    /// `parse_binding`; nil for trailing blanks, a comment, or a statement it cannot parse.
    private mutating func parseBinding() -> Binding? {
        do {
            skip(while: Self.isSpace)
            guard position < text.count else { return nil }
            skipExport()
            let key = try parseKey()
            skip(while: Self.isBlank)
            var value: String?
            if peek == "=" {
                position += 1
                skip(while: Self.isBlank)
                value = try parseValue()
            }
            skipComment()
            try readEndOfLine()
            return key.map { Binding(key: $0, value: value) }
        } catch {
            // `_rest_of_line`: up to and including one `\r` or `\n`.
            skip(while: { !Self.isLineEnd($0) })
            if position < text.count { position += 1 }
            return nil
        }
    }

    /// `(?:export[^\S\r\n]+)?`
    private mutating func skipExport() {
        let export = Array("export".unicodeScalars)
        let end = position + export.count
        guard end < text.count, Array(text[position..<end]) == export, Self.isBlank(text[end]) else { return }
        position = end
        skip(while: Self.isBlank)
    }

    /// nil for a comment; otherwise `'([^']+)'` or `[^=\#\s]+`.
    private mutating func parseKey() throws -> String? {
        switch peek {
        case "#":
            return nil
        case "'":
            guard let close = text[(position + 1)...].firstIndex(of: "'"), close > position + 1 else {
                throw Unparsable()
            }
            let key = Self.string(text[(position + 1)..<close])
            position = close + 1
            return key
        default:
            let start = position
            skip(while: { $0 != "=" && $0 != "#" && !Self.isSpace($0) })
            guard position > start else { throw Unparsable() }
            return Self.string(text[start..<position])
        }
    }

    private mutating func parseValue() throws -> String {
        switch peek {
        case "'": return Self.decoded(try readQuoted("'"), escapes: ["\\", "'"])
        case "\"": return Self.decoded(try readQuoted("\""), escapes: Self.doubleQuoteEscapes)
        case nil, "\n", "\r": return ""
        default: return readUnquoted()
        }
    }

    /// `'((?:\\'|[^'])*)'` and its double-quoted twin, backtracking included: the value runs to
    /// the first quote no backslash escapes, across lines; with none, to the last escaped one,
    /// whose backslash then ends the value.
    private mutating func readQuoted(_ quote: Unicode.Scalar) throws -> ArraySlice<Unicode.Scalar> {
        var index = position + 1
        var lastEscapedQuote: Int?
        while index < text.count, text[index] != quote {
            if text[index] == "\\", index + 1 < text.count, text[index + 1] == quote {
                lastEscapedQuote = index + 1
                index += 2
            } else {
                index += 1
            }
        }
        let close: Int? = index < text.count ? index : lastEscapedQuote
        guard let close else { throw Unparsable() }
        let value = text[(position + 1)..<close]
        position = close + 1
        return value
    }

    /// `[^\r\n]*`, then `re.sub(r"\s+#.*", "", …)` and `rstrip()`.
    private mutating func readUnquoted() -> String {
        let start = position
        skip(while: { !Self.isLineEnd($0) })
        var value = Array(text[start..<position])
        var index = 0
        while index < value.count {
            guard Self.isSpace(value[index]) else { index += 1; continue }
            var end = index
            while end < value.count, Self.isSpace(value[end]) { end += 1 }
            if end < value.count, value[end] == "#" {
                value.removeSubrange(index...)
                break
            }
            index = end
        }
        while let last = value.last, Self.isSpace(last) { value.removeLast() }
        return Self.string(value[...])
    }

    /// `(?:[^\S\r\n]*#[^\r\n]*)?`
    private mutating func skipComment() {
        var index = position
        while index < text.count, Self.isBlank(text[index]) { index += 1 }
        guard index < text.count, text[index] == "#" else { return }
        position = index
        skip(while: { !Self.isLineEnd($0) })
    }

    /// `[^\S\r\n]*(?:\r\n|\n|\r|$)`
    private mutating func readEndOfLine() throws {
        skip(while: Self.isBlank)
        guard position < text.count else { return }
        guard Self.isLineEnd(text[position]) else { throw Unparsable() }
        if text[position] == "\r", position + 1 < text.count, text[position + 1] == "\n" { position += 1 }
        position += 1
    }

    private var peek: Unicode.Scalar? { position < text.count ? text[position] : nil }

    private mutating func skip(while matches: (Unicode.Scalar) -> Bool) {
        while position < text.count, matches(text[position]) { position += 1 }
    }

    private static let doubleQuoteEscapes: Set<Unicode.Scalar> = ["\\", "'", "\"", "a", "b", "f", "n", "r", "t", "v"]

    /// Python's unicode-escape reading of each escape in `escapes`.
    private static let escaped: [Unicode.Scalar: Unicode.Scalar] = [
        "\\": "\\", "'": "'", "\"": "\"", "a": "\u{07}", "b": "\u{08}", "f": "\u{0C}",
        "n": "\n", "r": "\r", "t": "\t", "v": "\u{0B}",
    ]

    /// `decode_escapes`: each backslash and one of `escapes`, left to right; any other
    /// backslash stays.
    private static func decoded(_ value: ArraySlice<Unicode.Scalar>, escapes: Set<Unicode.Scalar>) -> String {
        var result = String.UnicodeScalarView()
        var index = value.startIndex
        while index < value.endIndex {
            let next = index + 1
            if value[index] == "\\", next < value.endIndex, escapes.contains(value[next]),
               let scalar = escaped[value[next]] {
                result.append(scalar)
                index = next + 1
            } else {
                result.append(value[index])
                index = next
            }
        }
        return String(result)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// Python's `\s` on a `str`: Unicode White_Space and the separators U+001C–U+001F.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// `[^\S\r\n]`: a blank that does not end a line.
    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        isSpace(scalar) && !isLineEnd(scalar)
    }

    private static func isLineEnd(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }
}
