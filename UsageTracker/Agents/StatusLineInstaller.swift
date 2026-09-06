import Foundation

/// Omelette's entry in Claude Code's `statusLine` setting.
///
/// The same rules as `AgentHooksInstaller`: we only ever touch a command that is ours,
/// a `settings.json` we cannot parse is a refusal rather than an overwrite, and the
/// file is copied to `settings.json.omelette-backup` before the first edit. Pure over
/// the URL it is handed, so the tests run against temp files.
enum StatusLineInstaller {
    typealias Error = SettingsFile.Error

    /// The symlink path, so an entry written by an older build still matches after the
    /// app moves. On its own it would also match `omelette-hook`, whose path begins
    /// with the same characters — see `isOurs`.
    static let ourCommandMarker = "UsageTracker/bin/omelette"

    static let subcommand = "statusline"

    static let unreadableReason = "settings.json has a statusLine Omelette can't read — fix or move it and try again."

    /// A Claude Code `statusLine.command` is a shell command line, not an argv path,
    /// and the CLI lives under "Application Support" — unquoted, the shell would try to
    /// run `/Users/…/Library/Application`.
    static func command(cliPath: String) -> String {
        AgentHooksInstaller.shellQuoted(cliPath) + " " + subcommand
    }

    /// Ours when it names the symlink *and* asks it for the status line. The marker
    /// alone is a prefix of the hook helper's path; the subcommand is what no hook
    /// command will ever carry.
    static func isOurs(_ command: String) -> Bool {
        command.contains(ourCommandMarker) && command.hasSuffix(" " + subcommand)
    }

    static func template(cliPath: String) -> [String: Any] {
        ["type": "command", "command": command(cliPath: cliPath)]
    }

    /// Exactly what the Enable button will write, for the Settings preview.
    static func previewJSON(cliPath: String) -> String {
        SettingsFile.prettyJSON(["statusLine": template(cliPath: cliPath)]) ?? "{}"
    }

    static func status(settingsURL: URL, cliPath: String) -> HookInstallStatus {
        guard let file = try? SettingsFile.readJSON(settingsURL) else {
            return .conflict(AgentHooksInstaller.unparsableReason)
        }
        guard let value = file["statusLine"] else { return .notInstalled }
        guard let object = value as? [String: Any], let existing = object["command"] as? String else {
            return .conflict(unreadableReason)
        }
        guard isOurs(existing) else { return .conflict(existing) }
        return SettingsFile.canonicalJSON(object) == SettingsFile.canonicalJSON(template(cliPath: cliPath))
            ? .installed : .outdated
    }

    /// Writes our entry, keeping every other key. A `statusLine` that is someone
    /// else's is a conflict, not something to overwrite — the UI shows their command
    /// and ours side by side instead.
    static func install(settingsURL: URL, cliPath: String) throws {
        var file = try SettingsFile.readJSON(settingsURL)
        if let existing = file["statusLine"] {
            guard let object = existing as? [String: Any], let command = object["command"] as? String else {
                throw Error.conflict(unreadableReason)
            }
            guard isOurs(command) else { throw Error.conflict(command) }
        }
        file["statusLine"] = template(cliPath: cliPath)
        try SettingsFile.writeJSON(file, to: settingsURL)
    }

    /// Deletes exactly our entry. `cliPath` is part of the shared signature and
    /// deliberately unused: ownership is `isOurs`, so an entry written by an older
    /// build with a different path goes too.
    static func remove(settingsURL: URL, cliPath: String) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var file = try SettingsFile.readJSON(settingsURL)
        guard let object = file["statusLine"] as? [String: Any],
              let command = object["command"] as? String,
              isOurs(command)
        else { return }                     // nothing of ours: do not reformat the file
        file.removeValue(forKey: "statusLine")
        try SettingsFile.writeJSON(file, to: settingsURL)
    }
}
