import Foundation

/// Reading and writing config files Omelette does not own.
///
/// Lifted out of `AgentHooksInstaller` when a second and a third installer needed the
/// same four guarantees: a missing file reads as empty, a file we cannot parse is a
/// refusal rather than an overwrite, the original is copied to `.omelette-backup`
/// before the first edit, and every write is atomic.
enum SettingsFile {
    enum Error: Swift.Error, Equatable {
        /// The file exists but is not the format it claims to be.
        case unparsable(URL)
        /// Someone else already owns the setting; the payload is their line.
        case conflict(String)
    }

    /// `~/.claude/settings.json` → `~/.claude/settings.json.omelette-backup`.
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("omelette-backup")
    }

    // MARK: - JSON

    /// Missing or blank file → `{}`. Anything else that is not a JSON object, or a
    /// file we cannot read, is a refusal.
    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { throw Error.unparsable(url) }
            return [:]
        }
        let blank = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? data.isEmpty
        if blank { return [:] }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Error.unparsable(url)
        }
        return dict
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        guard let data = prettyJSONData(object) else { throw Error.unparsable(url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try backupOnce(url)
        try writeAtomically(data, to: url)
    }

    /// Order-independent fingerprint of an object: re-serialising through
    /// `JSONSerialization` keeps `true` a boolean and `5` a number, which `as? Bool` on
    /// a bridged `NSNumber` would not.
    static func canonicalJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return text
    }

    static func prettyJSONData(_ object: Any) -> Data? {
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)          // editors and `git diff` both want the trailing newline
        return data
    }

    static func prettyJSON(_ object: Any) -> String? {
        prettyJSONData(object).flatMap { String(data: $0.dropLast(), encoding: .utf8) }
    }

    // MARK: - Text (TOML)

    /// Missing file → empty text. An existing file we cannot decode is a refusal:
    /// overwriting it would destroy a config we never read.
    static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { throw Error.unparsable(url) }
            return ""
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Error.unparsable(url) }
        return text
    }

    static func writeText(_ lines: [String], to url: URL) throws {
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try backupOnce(url)
        try writeAtomically(Data(text.utf8), to: url)
    }

    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Shared

    /// One-time safety copy next to the file. Never overwritten, so it always holds the
    /// file as it was before Omelette first edited it.
    private static func backupOnce(_ url: URL) throws {
        let backup = backupURL(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: url, to: backup)
    }

    /// Foundation's `.atomic` is exactly "write a temp file in the same directory, then
    /// rename": a crash or a full disk leaves the previous config intact instead of a
    /// half-written one.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}
