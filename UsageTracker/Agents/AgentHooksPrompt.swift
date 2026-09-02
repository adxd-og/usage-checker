import Foundation

/// Whether to offer the one-time "turn on precise agent status" prompt.
///
/// Hooks stay opt-in — nothing is written to `~/.claude/settings.json` without a
/// click — so this decides only whether to *ask*. Pure over its inputs, and the
/// file check takes its URLs, so a test never reaches the real `~/.claude`.
enum AgentHooksPrompt {
    /// Show the prompt only when there is something to gain and the user has not
    /// answered yet: Claude Code has been used on this machine, our hooks are not
    /// installed, and the prompt was not dismissed.
    ///
    /// `.outdated` and `.installed` never prompt — the hooks are already there and
    /// Settings → Agents owns the update — and neither does `.conflict`, where a
    /// one-click install would fail anyway.
    static func shouldShow(claudePresent: Bool, status: HookInstallStatus, dismissed: Bool) -> Bool {
        claudePresent && status == .notInstalled && !dismissed
    }

    /// What both Enable buttons — the popover row and the notification action —
    /// run, so the two can never install against different paths. The installer
    /// itself stays pure over its URLs; this is the one place that names the
    /// real ones.
    static func installClaudeHooks() throws {
        try AgentHooksInstaller.installClaude(
            settingsURL: AgentPaths.claudeSettingsURL,
            helperPath: AgentPaths.helperSymlinkURL.path
        )
    }

    /// Has Claude Code ever run here? Its project transcripts or a settings file
    /// of its own are the two traces it leaves whether or not hooks exist.
    static func claudeIsPresent(
        projectsURL: URL = AgentPaths.claudeProjectsURL,
        settingsURL: URL = AgentPaths.claudeSettingsURL
    ) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: projectsURL.path) || fm.fileExists(atPath: settingsURL.path)
    }
}
