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
    /// The installers share one error type — `AgentHooksInstaller.Error.unparsable` and
    /// `StatusLineInstaller.Error.unparsable` are the same case, because they are the
    /// same refusal about the same file.
    typealias Error = SettingsFile.Error

    /// A Claude hook entry is ours when its command contains this. The path is
    /// the App Support symlink, so an old entry still matches after the app moves.
    static let ourCommandMarker = "UsageTracker/bin/omelette-hook"

    /// Status-line text when settings.json is not JSON at all.
    static let unparsableReason = "settings.json isn't valid JSON — fix or move it and try again."
    /// Status-line text when config.toml exists but is not readable UTF-8 text.
    static let unreadableReason = "config.toml can't be read as UTF-8 text."

    /// `~/.claude/settings.json` → `~/.claude/settings.json.omelette-backup`.
    static func backupURL(for url: URL) -> URL { SettingsFile.backupURL(for: url) }

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
        hooksStatus(
            url: settingsURL,
            template: claudeTemplate(helperPath: helperPath),
            unparsable: unparsableReason
        )
    }

    /// Merges the template in, dropping any earlier version of ours first.
    /// Foreign keys, foreign events and foreign entries inside an event we also
    /// use all survive; the file comes back pretty-printed with sorted keys,
    /// which is why the original is copied to `.omelette-backup` beforehand.
    static func installClaude(settingsURL: URL, helperPath: String) throws {
        try mergeHooks(claudeTemplate(helperPath: helperPath), into: settingsURL)
    }

    /// Deletes exactly our entries. `helperPath` is part of the shared signature
    /// and deliberately unused: removal keys off `ourCommandMarker`, so an entry
    /// written by an older build with a different path goes too.
    static func removeClaude(settingsURL: URL, helperPath: String) throws {
        try removeHooks(from: settingsURL)
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
        SettingsFile.canonicalJSON(object)
    }

    /// Whether the entries of ours in `url` are exactly `template`'s. Shared by
    /// Claude's settings.json and Codex's hooks.json: the two files hold the same
    /// `hooks` object, so everything below this line is one implementation.
    private static func hooksStatus(url: URL, template: [String: Any], unparsable: String) -> HookInstallStatus {
        guard let file = try? readSettings(url),
              let hooks = try? hooksObject(in: file, url: url) else { return .conflict(unparsable) }
        let mine = ourEntries(in: hooks)
        if mine.isEmpty { return .notInstalled }
        return mine == ourEntries(in: template) ? .installed : .outdated
    }

    private static func mergeHooks(_ template: [String: Any], into url: URL) throws {
        var file = try readSettings(url)
        var hooks = stripOurs(from: try hooksObject(in: file, url: url))
        for (event, value) in template {
            guard let ours = value as? [[String: Any]] else { continue }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(contentsOf: ours)
            hooks[event] = groups
        }
        file["hooks"] = hooks
        try writeSettings(file, to: url)
    }

    private static func removeHooks(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var file = try readSettings(url)
        let hooks = try hooksObject(in: file, url: url)
        guard !ourEntries(in: hooks).isEmpty else { return }   // nothing of ours: do not reformat the file
        let cleaned = stripOurs(from: hooks)
        if cleaned.isEmpty {
            file.removeValue(forKey: "hooks")
        } else {
            file["hooks"] = cleaned
        }
        try writeSettings(file, to: url)
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

    /// Missing or blank file → `{}`. Anything else that is not a JSON object, or a
    /// file we cannot read, is a refusal.
    private static func readSettings(_ url: URL) throws -> [String: Any] {
        try SettingsFile.readJSON(url)
    }

    /// The `hooks` object, or a refusal when the key is there but is not one.
    private static func hooksObject(in settings: [String: Any], url: URL) throws -> [String: Any] {
        guard let value = settings["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Error.unparsable(url) }
        return hooks
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        try SettingsFile.writeJSON(settings, to: url)
    }

    // MARK: - Codex hooks

    /// Status-line text when hooks.json exists but is not JSON.
    static let hooksUnparsableReason = "hooks.json isn't valid JSON — fix or move it and try again."

    /// The events we register with Codex, in the order the trust line lists them —
    /// `PermissionRequest` first, because it is the one the user cares about.
    /// No `Notification` (Codex has none) and no `SubagentStart`/`SubagentStop`
    /// (Omelette does not draw Codex subagents).
    static let codexHookEvents = [
        "PermissionRequest", "SessionStart", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
    ]

    /// The `hooks` fragment we own in `~/.codex/hooks.json`. Same shape and the same
    /// timeout chain as Claude's — Codex 0.153.4 copied the format — with one
    /// difference: the command carries `--codex-hook`, which is how the helper tells
    /// a hook payload on stdin from the `notify` argv line it also answers to.
    static func codexHooksTemplate(helperPath: String) -> [String: Any] {
        let command = shellQuoted(helperPath) + " --codex-hook"
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
            "Stop": [group("", fireAndForget)],
            "SessionEnd": [group("", fireAndForget)],
        ]
    }

    /// Exactly what the Enable button will merge, for the Settings preview.
    static func codexHooksPreviewJSON(helperPath: String) -> String {
        prettyJSON(["hooks": codexHooksTemplate(helperPath: helperPath)]) ?? "{}"
    }

    static func codexHooksStatus(hooksURL: URL, helperPath: String) -> HookInstallStatus {
        hooksStatus(
            url: hooksURL,
            template: codexHooksTemplate(helperPath: helperPath),
            unparsable: hooksUnparsableReason
        )
    }

    /// A missing file becomes `{"hooks": {…}}`; an existing one keeps every foreign
    /// entry, including the `rtk hook claude` PreToolUse entry the owner's file has.
    static func installCodexHooks(hooksURL: URL, helperPath: String) throws {
        try mergeHooks(codexHooksTemplate(helperPath: helperPath), into: hooksURL)
    }

    /// `helperPath` is part of the shared signature and deliberately unused —
    /// ownership is `ourCommandMarker`, so an entry from an older build goes too.
    static func removeCodexHooks(hooksURL: URL, helperPath: String) throws {
        try removeHooks(from: hooksURL)
    }

    /// Whether Codex will actually run the hooks we installed. "Installed" is only
    /// half the story: a hook Codex has not been told to trust is refused in
    /// silence, so the Agents tab has to say so, and `PermissionBroker` must not
    /// offer Allow / Deny for a request that will never arrive.
    enum CodexTrustStatus: Equatable {
        case trusted
        /// The events of ours Codex is still ignoring, in `codexHookEvents` order.
        case awaitingTrust(untrusted: [String])
    }

    /// Reads the `[hooks.state]` table of config.toml and asks it about every entry
    /// of ours in hooks.json. The key is built from the hooks file's path, the event
    /// in snake case and the two indices of the entry inside that event's array —
    /// which is why this needs both files: the rtk hook owns `pre_tool_use:0:0`, so
    /// ours is `:1:0`, and a merge that moved it would move the key with it.
    ///
    /// We cannot compute Codex's `trusted_hash`; its presence (with `enabled` absent
    /// or true) is the whole test.
    static func codexTrust(configURL: URL, hooksURL: URL) -> CodexTrustStatus {
        guard let file = try? readSettings(hooksURL),
              let hooks = try? hooksObject(in: file, url: hooksURL)
        else { return .awaitingTrust(untrusted: codexHookEvents) }

        let table = trustTable(in: (try? readConfig(configURL)) ?? "")
        var untrusted: [String] = []
        var found = 0
        for event in codexHookEvents {
            for position in ourEntryPositions(in: hooks, event: event) {
                found += 1
                let key = codexTrustKey(
                    hooksPath: hooksURL.path, event: event,
                    entryIndex: position.entry, hookIndex: position.hook
                )
                if table[key] != true, !untrusted.contains(event) { untrusted.append(event) }
            }
        }
        guard found > 0 else { return .awaitingTrust(untrusted: codexHookEvents) }
        return untrusted.isEmpty ? .trusted : .awaitingTrust(untrusted: untrusted)
    }

    /// The `[hooks.state."…"]` key for one entry, as the path really reads. The
    /// header holds it as a TOML basic string, so `trustTable` unescapes it before
    /// the two are compared — a path with a quote or a backslash in it would
    /// otherwise depend on both sides spelling the escape the same way.
    static func codexTrustKey(hooksPath: String, event: String, entryIndex: Int, hookIndex: Int) -> String {
        "\(hooksPath):\(snakeCasedEvent(event)):\(entryIndex):\(hookIndex)"
    }

    /// `PermissionRequest` → `permission_request`, the spelling Codex writes.
    static func snakeCasedEvent(_ event: String) -> String {
        var out = ""
        for character in event {
            if character.isUppercase, !out.isEmpty { out.append("_") }
            out.append(contentsOf: character.lowercased())
        }
        return out
    }

    // MARK: - Codex trust internals

    /// Where our entries sit inside one event's array — the two indices the trust
    /// key is built from.
    private static func ourEntryPositions(in hooks: [String: Any], event: String) -> [(entry: Int, hook: Int)] {
        guard let groups = hooks[event] as? [[String: Any]] else { return [] }
        var out: [(entry: Int, hook: Int)] = []
        for (entryIndex, group) in groups.enumerated() {
            guard let entries = group["hooks"] as? [[String: Any]] else { continue }
            for (hookIndex, entry) in entries.enumerated() where isOurs(entry) {
                out.append((entryIndex, hookIndex))
            }
        }
        return out
    }

    /// Every `[hooks.state."<key>"]` header mapped to "Codex will run this": a
    /// non-empty `trusted_hash` and no `enabled = false`. Hand-rolled rather than a
    /// TOML library because this is one table of a file we only ever read, and the
    /// header is the only line whose shape we depend on.
    private static func trustTable(in text: String) -> [String: Bool] {
        var table: [String: Bool] = [:]
        var key: String?
        var hasHash = false
        var enabled = true
        func flush() {
            if let key { table[key] = hasHash && enabled }
            key = nil
            hasHash = false
            enabled = true
        }
        for raw in lines(of: text) {
            let line = interpretable(raw)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                flush()
                key = stateKey(inHeader: line)
                continue
            }
            guard key != nil, let (name, value) = assignment(line) else { continue }
            switch name {
            case "trusted_hash":
                if let hash = tomlUnquoted(value), !hash.isEmpty { hasHash = true }
            case "enabled":
                if value == "false" { enabled = false }
            default:
                break
            }
        }
        flush()
        return table
    }

    /// One line ready to interpret: no carriage return from a CRLF file, no trailing
    /// `# comment`, no surrounding whitespace. A `#` inside a quoted string is part
    /// of the string — a path may contain one.
    private static func interpretable(_ raw: String) -> String {
        var out = ""
        var inQuotes = false
        var escaped = false
        for character in raw where character != "\r" {
            if escaped {
                out.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                out.append(character)
                escaped = true
            case "\"":
                inQuotes.toggle()
                out.append(character)
            case "#" where !inQuotes:
                return out.trimmingCharacters(in: .whitespaces)
            default:
                out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// `key = value` split on the first `=` outside quotes. The key may be bare or
    /// quoted — Codex writes `enabled = false`, but `"enabled" = false` is the same
    /// key and the same answer.
    private static func assignment(_ line: String) -> (name: String, value: String)? {
        var inQuotes = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\", inQuotes { escaped = true; continue }
            if character == "\"" { inQuotes.toggle(); continue }
            guard character == "=", !inQuotes else { continue }
            let rawName = String(line[..<index]).trimmingCharacters(in: .whitespaces)
            let name = tomlUnquoted(rawName) ?? rawName
            let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
        return nil
    }

    /// `[hooks.state."…"]` → the key the path really spells; nil for any other
    /// header.
    private static func stateKey(inHeader line: String) -> String? {
        let prefix = "[hooks.state."
        guard line.hasPrefix(prefix), line.hasSuffix("]") else { return nil }
        let quoted = String(line.dropFirst(prefix.count).dropLast()).trimmingCharacters(in: .whitespaces)
        guard let key = tomlUnquoted(quoted), !key.isEmpty else { return nil }
        return key
    }

    /// The contents of a TOML basic string, with `\"` and `\\` resolved; nil when
    /// `text` is not one. Those two escapes are the ones a path produces, and this
    /// reads one table of a file we never write — anything else is left as it is.
    private static func tomlUnquoted(_ text: String) -> String? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        var out = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                if character != "\"", character != "\\" { out.append("\\") }
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
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

    private static func lines(of text: String) -> [String] { SettingsFile.lines(of: text) }

    private static func tomlEscaped(_ value: String) -> String { SettingsFile.tomlEscaped(value) }

    /// Missing file → empty text. An existing file we cannot decode is a refusal.
    private static func readConfig(_ url: URL) throws -> String { try SettingsFile.readText(url) }

    private static func writeConfig(_ all: [String], to url: URL) throws {
        try SettingsFile.writeText(all, to: url)
    }

    // MARK: - Shared file plumbing

    private static func prettyJSONData(_ object: Any) -> Data? { SettingsFile.prettyJSONData(object) }

    private static func prettyJSON(_ object: Any) -> String? { SettingsFile.prettyJSON(object) }
}
