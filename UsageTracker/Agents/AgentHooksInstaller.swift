import Foundation

/// Where our entries stand in a config file we do not own. `conflict` carries
/// the text to put in front of the user: the foreign `notify` line for Codex,
/// a one-line reason for a `settings.json` we refuse to touch.
enum HookInstallStatus: Equatable {
    case installed
    case outdated
    case notInstalled
    case conflict(String)
}

/// Installs and removes Omelette's entries in the agents' own config files.
///
/// Every function is pure over the URLs it is handed, so the tests run against
/// temp files and nothing here can reach `~/.claude` or `~/.codex` by accident.
/// Two rules hold throughout: we only ever touch entries that carry
/// `ourCommandMarker`, and a file we cannot parse is a refusal, never an
/// overwrite.
enum AgentHooksInstaller {
    enum Error: Swift.Error, Equatable {
        /// The file exists but is not the format it claims to be.
        case unparsable(URL)
        /// Someone else already owns the setting; the payload is their line.
        case conflict(String)
    }

    /// A Claude hook entry is ours when its command contains this. The path is
    /// the App Support symlink, so an old entry still matches after the app moves.
    static let ourCommandMarker = "UsageTracker/bin/omelette-hook"

    /// Status-line text when settings.json is not JSON at all.
    static let unparsableReason = "settings.json isn't valid JSON — fix or move it and try again."
    /// Status-line text when config.toml exists but is not readable UTF-8 text.
    static let unreadableReason = "config.toml can't be read as UTF-8 text."

    /// `~/.claude/settings.json` → `~/.claude/settings.json.omelette-backup`.
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("omelette-backup")
    }

    // MARK: - Claude

    /// The `hooks` fragment we own. Async everywhere so Claude Code never waits
    /// on us; `PermissionRequest` is the single synchronous entry, and since 2.2.0
    /// it is registered with a 150 s cap so Omelette can hold it while you decide.
    /// The chain is deliberate: the app releases at 120 s and the helper at 140 s,
    /// so Claude Code's own timeout is never the one that fires. The two
    /// `Notification` entries are literal matchers rather than one alternation,
    /// so each notification type we listen to is separately visible in the file.
    /// A Claude Code hook `command` is a shell command line, not an argv path,
    /// and the helper lives under "Application Support" — unquoted, the shell
    /// would try to run `/Users/…/Library/Application`. Single quotes survive
    /// every character except the quote itself, which becomes `'\''`.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func claudeTemplate(helperPath: String) -> [String: Any] {
        let command = shellQuoted(helperPath)
        let fireAndForget: [String: Any] = ["type": "command", "command": command, "async": true]
        let blocking: [String: Any] = ["type": "command", "command": command, "timeout": 150]
        func group(_ matcher: String, _ entry: [String: Any]) -> [String: Any] {
            ["matcher": matcher, "hooks": [entry]]
        }
        return [
            "SessionStart": [group("", fireAndForget)],
            "UserPromptSubmit": [group("", fireAndForget)],
            "PreToolUse": [group("", fireAndForget)],
            "PostToolUse": [group("", fireAndForget)],
            "PermissionRequest": [group("", blocking)],
            "Notification": [group("permission_prompt", fireAndForget), group("idle_prompt", fireAndForget)],
            "Stop": [group("", fireAndForget)],
            "SessionEnd": [group("", fireAndForget)],
        ]
    }

    /// Exactly what the Enable button will merge, for the Settings preview.
    static func claudePreviewJSON(helperPath: String) -> String {
        prettyJSON(["hooks": claudeTemplate(helperPath: helperPath)]) ?? "{}"
    }

    static func claudeStatus(settingsURL: URL, helperPath: String) -> HookInstallStatus {
        guard let hooks = try? hooksObject(in: readSettings(settingsURL), url: settingsURL) else {
            return .conflict(unparsableReason)
        }
        let mine = ourEntries(in: hooks)
        if mine.isEmpty { return .notInstalled }
        return mine == ourEntries(in: claudeTemplate(helperPath: helperPath)) ? .installed : .outdated
    }

    /// Merges the template in, dropping any earlier version of ours first.
    /// Foreign keys, foreign events and foreign entries inside an event we also
    /// use all survive; the file comes back pretty-printed with sorted keys,
    /// which is why the original is copied to `.omelette-backup` beforehand.
    static func installClaude(settingsURL: URL, helperPath: String) throws {
        var settings = try readSettings(settingsURL)
        var hooks = stripOurs(from: try hooksObject(in: settings, url: settingsURL))
        for (event, value) in claudeTemplate(helperPath: helperPath) {
            guard let ours = value as? [[String: Any]] else { continue }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(contentsOf: ours)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings, to: settingsURL)
    }

    /// Deletes exactly our entries. `helperPath` is part of the shared signature
    /// and deliberately unused: removal keys off `ourCommandMarker`, so an entry
    /// written by an older build with a different path goes too.
    static func removeClaude(settingsURL: URL, helperPath: String) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var settings = try readSettings(settingsURL)
        let hooks = try hooksObject(in: settings, url: settingsURL)
        guard !ourEntries(in: hooks).isEmpty else { return }   // nothing of ours: do not reformat the file
        let cleaned = stripOurs(from: hooks)
        if cleaned.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = cleaned
        }
        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - Claude internals

    /// Order-independent fingerprint of the entries we own, one string per
    /// entry: "<Event>\u{1}<matcher>\u{1}<hook object as sorted-key JSON>".
    /// Re-serialising through JSONSerialization keeps `true` a boolean and `5`
    /// a number, which `as? Bool` on a bridged NSNumber would not.
    private static func ourEntries(in hooks: [String: Any]) -> [String] {
        var out: [String] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let matcher = group["matcher"] as? String ?? ""
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                for entry in entries where isOurs(entry) {
                    out.append("\(event)\u{1}\(matcher)\u{1}\(canonicalJSON(entry))")
                }
            }
        }
        return out.sorted()
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(ourCommandMarker) == true
    }

    private static func canonicalJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
        return text
    }

    /// Removes every entry of ours, keeping foreign entries — including one that
    /// shares a matcher group with ours — and pruning groups and events left empty.
    private static func stripOurs(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                out[event] = value          // a shape we do not understand: leave it exactly as it is
                continue
            }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    kept.append(group)
                    continue
                }
                let survivors = entries.filter { !isOurs($0) }
                if survivors.isEmpty { continue }
                group["hooks"] = survivors
                kept.append(group)
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    /// Missing or blank file → `{}`. Anything else that is not a JSON object,
    /// or a file we cannot read, is a refusal.
    private static func readSettings(_ url: URL) throws -> [String: Any] {
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

    /// The `hooks` object, or a refusal when the key is there but is not one.
    private static func hooksObject(in settings: [String: Any], url: URL) throws -> [String: Any] {
        guard let value = settings["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Error.unparsable(url) }
        return hooks
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        guard let data = prettyJSONData(settings) else { throw Error.unparsable(url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try backupOnce(url)
        try writeAtomically(data, to: url)
    }

    // MARK: - Codex

    /// The one line we own in config.toml.
    static func codexNotifyLine(helperPath: String) -> String {
        "notify = [\"\(tomlEscaped(helperPath))\", \"--codex\"]"
    }

    static func codexStatus(configURL: URL, helperPath: String) -> HookInstallStatus {
        guard let text = try? readConfig(configURL) else { return .conflict(unreadableReason) }
        guard let found = topLevelNotify(in: text) else { return .notInstalled }
        let line = found.line.trimmingCharacters(in: .whitespaces)
        if line == codexNotifyLine(helperPath: helperPath) { return .installed }
        if line.contains(ourCommandMarker) { return .outdated }
        return .conflict(line)
    }

    /// Adds or refreshes our `notify` line. A `notify` that is someone else's is
    /// a conflict, not something to overwrite — the UI shows their line and ours
    /// side by side instead.
    static func installCodex(configURL: URL, helperPath: String) throws {
        guard let text = try? readConfig(configURL) else { throw Error.conflict(unreadableReason) }
        let ours = codexNotifyLine(helperPath: helperPath)
        var all = lines(of: text)

        if let found = topLevelNotify(in: text) {
            let existing = found.line.trimmingCharacters(in: .whitespaces)
            if existing == ours { return }
            guard existing.contains(ourCommandMarker) else { throw Error.conflict(existing) }
            all[found.index] = ours
        } else {
            while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
            let index = topLevelInsertIndex(in: all)
            all.insert(contentsOf: index < all.count ? [ours, ""] : [ours], at: index)
        }
        try writeConfig(all, to: configURL)
    }

    /// Removes our line only. A foreign `notify` is left exactly where it is.
    /// `helperPath` is part of the shared signature; ownership is decided by
    /// `ourCommandMarker`, so a line from an older build goes too.
    static func removeCodex(configURL: URL, helperPath: String) throws {
        guard let text = try? readConfig(configURL) else { throw Error.conflict(unreadableReason) }
        guard let found = topLevelNotify(in: text), found.line.contains(ourCommandMarker) else { return }
        var all = lines(of: text)
        all.remove(at: found.index)
        try writeConfig(all, to: configURL)
    }

    // MARK: - Codex internals

    /// The index and raw text of the top-level `notify = …` line, if any.
    /// The top level ends at the first `[table]` (or `[[array]]`) header;
    /// comments never count.
    private static func topLevelNotify(in text: String) -> (index: Int, line: String)? {
        for (index, raw) in lines(of: text).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("notify") else { continue }
            let rest = line.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { return (index, raw) }
        }
        return nil
    }

    /// Just before the first table header, so the key stays top-level; the end
    /// of the file when there is no table.
    private static func topLevelInsertIndex(in all: [String]) -> Int {
        for (index, raw) in all.enumerated()
        where raw.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            return index
        }
        return all.count
    }

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Missing file → empty text. An existing file we cannot decode is a
    /// refusal: overwriting it would destroy a config we never read.
    private static func readConfig(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            if FileManager.default.fileExists(atPath: url.path) { throw Error.unparsable(url) }
            return ""
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Error.unparsable(url) }
        return text
    }

    private static func writeConfig(_ all: [String], to url: URL) throws {
        var text = all.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try backupOnce(url)
        try writeAtomically(Data(text.utf8), to: url)
    }

    // MARK: - Shared file plumbing

    /// One-time safety copy next to the file. Never overwritten, so it always
    /// holds the file as it was before Omelette first edited it.
    private static func backupOnce(_ url: URL) throws {
        let backup = backupURL(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: url, to: backup)
    }

    /// Foundation's `.atomic` is exactly "write a temp file in the same
    /// directory, then rename": a crash or a full disk leaves the previous
    /// config intact instead of a half-written one.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    private static func prettyJSONData(_ object: Any) -> Data? {
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)          // editors and `git diff` both want the trailing newline
        return data
    }

    private static func prettyJSON(_ object: Any) -> String? {
        prettyJSONData(object).flatMap { String(data: $0.dropLast(), encoding: .utf8) }
    }
}
