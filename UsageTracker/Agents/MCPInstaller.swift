import Foundation

/// Omelette's MCP server in the two agents' own config files.
///
/// Claude Code keeps MCP servers in `~/.claude.json` under `mcpServers`; Codex keeps
/// them in `[mcp_servers.<name>]` tables of `~/.codex/config.toml`. Both entries are
/// **argv**, not shell lines: the path goes in unquoted and `mcp` is a separate
/// argument, which is why `AgentHooksInstaller.shellQuoted` appears nowhere here.
///
/// The same two rules as every other installer: we only ever touch an entry that is
/// ours, and a file we cannot parse is a refusal rather than an overwrite.
enum MCPInstaller {
    typealias Error = SettingsFile.Error

    /// The server's name in both files, and what an agent will call the tools through.
    static let serverKey = "omelette"

    /// An entry is ours when its command names the symlink, so one written by an older
    /// build still matches after the app moves. Unlike the status line there is no
    /// suffix to check: `omelette-hook` is never an MCP server, and the key is ours.
    static let ourCommandMarker = "UsageTracker/bin/omelette"

    static let argument = "mcp"

    static let claudeUnparsableReason = ".claude.json isn't valid JSON — fix or move it and try again."
    static let claudeUnreadableReason = ".claude.json has an `omelette` MCP server Omelette can't read — fix or move it and try again."
    static let codexUnreadableReason = "config.toml can't be read as UTF-8 text."
    static let codexUnreadableTableReason = "config.toml has an [mcp_servers.omelette] table with no command — fix or move it and try again."

    // MARK: - Claude Code (~/.claude.json)

    static func claudeTemplate(cliPath: String) -> [String: Any] {
        ["type": "stdio", "command": cliPath, "args": [argument]]
    }

    /// Exactly what the Enable button will merge, for the Settings preview.
    static func claudePreviewJSON(cliPath: String) -> String {
        SettingsFile.prettyJSON(["mcpServers": [serverKey: claudeTemplate(cliPath: cliPath)]]) ?? "{}"
    }

    static func claudeStatus(configURL: URL, cliPath: String) -> HookInstallStatus {
        guard let file = try? SettingsFile.readJSON(configURL) else { return .conflict(claudeUnparsableReason) }
        guard let servers = file["mcpServers"] else { return .notInstalled }
        guard let map = servers as? [String: Any] else { return .conflict(claudeUnparsableReason) }
        guard let entry = map[serverKey] else { return .notInstalled }
        guard let object = entry as? [String: Any], let command = object["command"] as? String else {
            return .conflict(claudeUnreadableReason)
        }
        guard command.contains(ourCommandMarker) else { return .conflict(command) }
        return SettingsFile.canonicalJSON(object) == SettingsFile.canonicalJSON(claudeTemplate(cliPath: cliPath))
            ? .installed : .outdated
    }

    /// Merges our server in, keeping every other key of a file Claude Code writes
    /// itself — project history, onboarding flags, other servers. It comes back
    /// pretty-printed with sorted keys, which is why the original is copied to
    /// `.claude.json.omelette-backup` first.
    static func installClaude(configURL: URL, cliPath: String) throws {
        var file = try SettingsFile.readJSON(configURL)
        var map: [String: Any] = [:]
        if let servers = file["mcpServers"] {
            // A `mcpServers` that is not an object is a file we do not understand, and
            // replacing it would throw away whatever it really held.
            guard let existing = servers as? [String: Any] else { throw Error.unparsable(configURL) }
            map = existing
        }
        if let entry = map[serverKey] {
            guard let object = entry as? [String: Any], let command = object["command"] as? String else {
                throw Error.conflict(claudeUnreadableReason)
            }
            guard command.contains(ourCommandMarker) else { throw Error.conflict(command) }
        }
        map[serverKey] = claudeTemplate(cliPath: cliPath)
        file["mcpServers"] = map
        try SettingsFile.writeJSON(file, to: configURL)
    }

    /// Deletes exactly our entry, and the `mcpServers` map with it when nothing else
    /// is left — an empty object is clutter in a file we do not own.
    static func removeClaude(configURL: URL, cliPath: String) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        var file = try SettingsFile.readJSON(configURL)
        guard var map = file["mcpServers"] as? [String: Any],
              let object = map[serverKey] as? [String: Any],
              let command = object["command"] as? String,
              command.contains(ourCommandMarker)
        else { return }                     // nothing of ours: do not reformat the file
        map.removeValue(forKey: serverKey)
        if map.isEmpty {
            file.removeValue(forKey: "mcpServers")
        } else {
            file["mcpServers"] = map
        }
        try SettingsFile.writeJSON(file, to: configURL)
    }

    // MARK: - Codex (~/.codex/config.toml)

    static let codexHeader = "[mcp_servers.\(serverKey)]"

    static func codexTable(cliPath: String) -> [String] {
        [
            codexHeader,
            "command = \"\(SettingsFile.tomlEscaped(cliPath))\"",
            "args = [\"\(argument)\"]",
        ]
    }

    /// Exactly what the Enable button will append, for the Settings preview.
    static func codexPreview(cliPath: String) -> String {
        codexTable(cliPath: cliPath).joined(separator: "\n")
    }

    /// Our table's lines: the header, and everything up to the next header — except a
    /// sub-table of ours (`[mcp_servers.omelette.env]`), which belongs to it. Leaving
    /// an orphan sub-table behind would give Codex a config it refuses to parse.
    static func codexTableRange(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { codexInterpreted($0) == codexHeader })
        else { return nil }
        var end = start + 1
        while end < lines.count {
            let line = codexInterpreted(lines[end])
            if line.hasPrefix("["), !line.hasPrefix("[mcp_servers.\(serverKey).") { break }
            end += 1
        }
        return start..<end
    }

    /// One line ready to interpret: no carriage return from a CRLF file, no surrounding
    /// whitespace. `.trimmingCharacters(in: .whitespaces)` leaves "\r" exactly where it
    /// is — CR is a control character, not a space — so a `config.toml` with Windows
    /// line endings would never match `codexHeader`, and install would append a second
    /// table beside the one already there. `AgentHooksInstaller.interpretable` strips it
    /// for the same reason.
    private static func codexInterpreted(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The line ending the file already uses, so a CRLF config stays CRLF. Untouched
    /// lines keep their own "\r" (the split is on "\n"); only the lines we add have to
    /// be told which file they are joining.
    private static func codexLineEnding(in text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    /// Our table's lines, punctuated for the file they are going into. `SettingsFile`
    /// joins with "\n", so a CRLF file gets its "\r" appended here.
    private static func codexLines(_ lines: [String], lineEnding: String) -> [String] {
        guard lineEnding == "\r\n" else { return lines }
        return lines.map { $0 + "\r" }
    }

    /// `key = "value"` inside a table's lines, unescaped. Hand-rolled for the same
    /// reason `AgentHooksInstaller.trustTable` is: this reads two keys of a file we
    /// otherwise only append to.
    static func codexValue(_ key: String, in lines: [String]) -> String? {
        for raw in lines {
            let line = codexInterpreted(raw)
            guard line.hasPrefix(key) else { continue }
            let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    static func codexStatus(configURL: URL, cliPath: String) -> HookInstallStatus {
        guard let text = try? SettingsFile.readText(configURL) else { return .conflict(codexUnreadableReason) }
        let lines = SettingsFile.lines(of: text)
        guard let range = codexTableRange(in: lines) else { return .notInstalled }
        let body = Array(lines[range])
        guard let command = codexValue("command", in: body) else { return .conflict(codexUnreadableTableReason) }
        guard command.contains(ourCommandMarker) else { return .conflict(command) }
        let meaningful = body.map(codexInterpreted).filter { !$0.isEmpty }
        return meaningful == codexTable(cliPath: cliPath) ? .installed : .outdated
    }

    /// Replaces our table where it is, or appends one at the end of the file. Appended
    /// rather than inserted before the first table, unlike `notify`: a table header
    /// ends the top level, so anything after it is already inside some table and ours
    /// has to start its own.
    static func installCodex(configURL: URL, cliPath: String) throws {
        guard let text = try? SettingsFile.readText(configURL) else { throw Error.conflict(codexUnreadableReason) }
        var lines = SettingsFile.lines(of: text)
        let table = codexTable(cliPath: cliPath)
        // Whatever the file already uses. Rewriting a CRLF config as LF would show up
        // as a whole-file diff in someone's dotfiles repo.
        let written = codexLines(table + [""], lineEnding: codexLineEnding(in: text))

        if let range = codexTableRange(in: lines) {
            let body = Array(lines[range])
            guard let command = codexValue("command", in: body) else { throw Error.conflict(codexUnreadableTableReason) }
            guard command.contains(ourCommandMarker) else { throw Error.conflict(command) }
            let meaningful = body.map(codexInterpreted).filter { !$0.isEmpty }
            if meaningful == table { return }
            lines.replaceSubrange(range, with: written)
        } else {
            while let last = lines.last, codexInterpreted(last).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append(contentsOf: codexLines([""], lineEnding: codexLineEnding(in: text))) }
            lines.append(contentsOf: written)
        }
        try SettingsFile.writeText(lines, to: configURL)
    }

    /// Removes our table only. A foreign `[mcp_servers.omelette]` is left exactly where
    /// it is. `cliPath` is part of the shared signature and deliberately unused:
    /// ownership is `ourCommandMarker`, so a table from an older build goes too.
    static func removeCodex(configURL: URL, cliPath: String) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        guard let text = try? SettingsFile.readText(configURL) else { throw Error.conflict(codexUnreadableReason) }
        var lines = SettingsFile.lines(of: text)
        guard let range = codexTableRange(in: lines),
              let command = codexValue("command", in: Array(lines[range])),
              command.contains(ourCommandMarker)
        else { return }
        lines.removeSubrange(range)
        try SettingsFile.writeText(lines, to: configURL)
    }
}
