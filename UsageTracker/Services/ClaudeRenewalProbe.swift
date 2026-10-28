import Foundation

/// One renewal start of Claude Code (spec 2026-10-25 § Design › Package 2, Renewal through
/// Claude Code): in Omelette's own folder, under a session id Omelette keeps, with Claude Code's
/// own flags, for `window` seconds, and any transcript under `~/.claude/projects` removed before
/// and after.
///
/// Not CodexBarCore's `touchOAuthAuthPath`: its folder is CodexBar's, it presses Enter every
/// 0.8 s, and its transcript cleaner is internal (plan Decision D1). The cleaner below is a port
/// of CodexBar's `ClaudeProbeSessionArtifactCleaner` (MIT, Peter Steinberger).
enum ClaudeRenewalProbe {
    /// How long Claude Code runs. Renewal happens as it starts; the rest is margin.
    static let window: TimeInterval = 8
    static let sessionIDFileName = "session-id"

    /// `~/Library/Application Support/UsageTracker/ClaudeRenewal`.
    static var directory: URL {
        AgentPaths.appSupportURL.appendingPathComponent("ClaudeRenewal", isDirectory: true)
    }

    /// `~/.claude`: the start runs without `CLAUDE_CONFIG_DIR`, so this is Claude Code's root.
    static var claudeRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
    }

    /// CodexBar's flags (`ClaudeCLISession.launchArguments`): no tool allowed, none of the
    /// user's MCP servers started, and one session id for every start.
    static func arguments(sessionID: String) -> [String] {
        ["--allowed-tools", "", "--strict-mcp-config", "--session-id", sessionID]
    }

    /// The persisted id, made on first use (0600, lowercase).
    static func sessionID(in directory: URL) -> String {
        if let stored = storedSessionID(in: directory) { return stored }
        let id = UUID().uuidString.lowercased()
        let file = directory.appendingPathComponent(sessionIDFileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? id.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return id
    }

    /// The id if one was made: what the passive scanner leaves out. nil before the first start.
    static func storedSessionID(in directory: URL) -> String? {
        let file = directory.appendingPathComponent(sessionIDFileName)
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return id.uuidString.lowercased()
    }

    /// Claude Code's name for a project folder: every character but [0-9A-Za-z] becomes "-";
    /// past 200 characters, the first 200 and a base-36 hash of the path.
    static func projectDirectoryName(for directory: URL) -> String {
        let path = directory.path.precomposedStringWithCanonicalMapping
        let sanitized = String(path.utf16.map { unit -> Character in
            switch unit {
            case 48...57, 65...90, 97...122: return Character(UnicodeScalar(unit)!)
            default: return "-"
            }
        })
        guard sanitized.count > 200 else { return sanitized }
        return "\(sanitized.prefix(200))-\(javaScriptHashBase36(path))"
    }

    /// Removes the `.jsonl` files under `<claudeRoot>/projects/<the folder's name>`, and the
    /// folder once it is empty. Anything else is left.
    @discardableResult
    static func removeTranscripts(probeDirectory: URL, claudeRoot: URL) -> [URL] {
        let fileManager = FileManager.default
        let folder = claudeRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirectoryName(for: probeDirectory), isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [URL] = []
        for entry in entries where entry.pathExtension == "jsonl" {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed.append(entry) }
        }
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
        return removed
    }

    /// One renewal: clean, start, clean. `start` runs Claude Code; the real one is
    /// `ClaudePTYStart.run`.
    static func renew(
        binary: String,
        directory: URL,
        claudeRoot: URL,
        environment: [String: String],
        start: (_ binary: String, _ arguments: [String], _ environment: [String: String], _ directory: URL) async -> Void
    ) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A start cut short (a crash, a quit) can have left one, and Claude Code refuses
        // `--session-id` for a session whose transcript exists.
        removeTranscripts(probeDirectory: directory, claudeRoot: claudeRoot)
        let id = sessionID(in: directory)
        await start(binary, arguments(sessionID: id), environment, directory)
        // Success or not: no transcript of this start stays behind.
        removeTranscripts(probeDirectory: directory, claudeRoot: claudeRoot)
    }

    /// The real renewal start: Omelette's environment made clean, the login shell's PATH, and
    /// Claude Code on a terminal of its own for `window` seconds.
    static func startForRenewal(binary: String) async {
        let environment = ClaudeCLIEnvironment.renewal(
            base: ProcessInfo.processInfo.environment,
            loginPATH: ClaudeBinaryLocator.loginPATH(),
            home: NSHomeDirectory(),
            user: NSUserName()
        )
        await renew(binary: binary, directory: directory, claudeRoot: claudeRoot, environment: environment) {
            binary, arguments, environment, directory in
            try? await ClaudePTYStart.run(
                binary: binary, arguments: arguments, environment: environment,
                directory: directory, duration: window
            )
        }
    }

    private static func javaScriptHashBase36(_ string: String) -> String {
        var hash: Int32 = 0
        for unit in string.utf16 {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: unit)
        }
        let magnitude = hash < 0 ? -Int64(hash) : Int64(hash)
        return String(magnitude, radix: 36)
    }
}
