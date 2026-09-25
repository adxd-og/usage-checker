import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "Integrations: Claude Code (hooks, status line,
/// MCP), Codex (hooks, notify, MCP), permissions, command line; replaces Agents tab +
/// CommandLineSettingsView in General" (`Settings-Integrations.dc.html`), with status as a
/// dot and text. The 2.x text rules (`AgentsSettingsText`, `CommandLineSettingsText`)
/// keep their own tests.
final class IntegrationsSettingsCopyTests: XCTestCase {
    private let awaiting = AgentHooksInstaller.CodexTrustStatus.awaitingTrust(
        untrusted: ["PermissionRequest", "PreToolUse"]
    )

    // MARK: Status

    func testTheDotFollowsThe2xColours() {
        XCTAssertEqual(AgentsSettingsText.hookStatusDot(.installed), .ok)
        XCTAssertEqual(AgentsSettingsText.hookStatusDot(.outdated), .warning)
        XCTAssertEqual(AgentsSettingsText.hookStatusDot(.notInstalled), .muted)
        XCTAssertEqual(AgentsSettingsText.hookStatusDot(.conflict("x")), .critical)
    }

    func testAnInstallersStateIsADotAndItsWords() {
        XCTAssertEqual(IntegrationsSettingsCopy.installStatus(.installed), SettingsStatus(text: "Installed", dot: .ok))
        XCTAssertEqual(IntegrationsSettingsCopy.installStatus(.notInstalled), SettingsStatus(text: "Not installed", dot: .muted))
        XCTAssertEqual(
            IntegrationsSettingsCopy.installStatus(.outdated),
            SettingsStatus(text: "Installed — older than this build", dot: .warning)
        )
        XCTAssertEqual(
            IntegrationsSettingsCopy.installStatus(.conflict("x")),
            SettingsStatus(text: "Can't write — something else owns this", dot: .critical)
        )
    }

    // MARK: Notes

    func testCodexHooksAwaitingTrustSayWhatIsLeftInAmber() {
        XCTAssertEqual(
            IntegrationsSettingsCopy.codexTrustNote(hooks: .installed, trust: awaiting),
            SettingsCaption(
                text: "Run /hooks in Codex once and trust the Omelette hooks (2 awaiting) — until then Codex ignores them",
                token: .warning
            )
        )
    }

    func testTrustedOrUninstalledCodexHooksNeedNoNote() {
        XCTAssertNil(IntegrationsSettingsCopy.codexTrustNote(hooks: .installed, trust: .trusted))
        XCTAssertNil(IntegrationsSettingsCopy.codexTrustNote(hooks: .notInstalled, trust: awaiting))
    }

    func testPermissionsSayWhyTheyDoNothingYet() {
        XCTAssertEqual(
            IntegrationsSettingsCopy.permissionsNote(claude: .notInstalled, codexHooks: .notInstalled, codexTrust: awaiting),
            SettingsCaption(
                text: "Inactive until the Claude Code or Codex hooks above are installed (and, for Codex, trusted).",
                token: .warning
            )
        )
        XCTAssertNil(IntegrationsSettingsCopy.permissionsNote(claude: .installed, codexHooks: .notInstalled, codexTrust: awaiting))
    }

    func testAStatusLineSomeoneElseOwnsIsQuoted() {
        XCTAssertEqual(
            IntegrationsSettingsCopy.statusLineConflictNote(.conflict("bash ~/sl.sh")),
            SettingsCaption(text: CommandLineSettingsText.conflictCaption("bash ~/sl.sh"), token: .secondary)
        )
        XCTAssertNil(IntegrationsSettingsCopy.statusLineConflictNote(.installed))
    }

    func testACodexNotifySomeoneElseOwnsIsQuoted() {
        XCTAssertEqual(
            IntegrationsSettingsCopy.codexNotifyConflictNote(.conflict(#"notify = ["x"]"#)),
            SettingsCaption(text: "config.toml already has a notify of its own:\n" + #"notify = ["x"]"#, token: .secondary)
        )
        XCTAssertNil(IntegrationsSettingsCopy.codexNotifyConflictNote(.notInstalled))
    }

    func testOnlyAConflictOffersToCopyOurLine() {
        XCTAssertTrue(IntegrationsSettingsCopy.isConflict(.conflict("x")))
        XCTAssertFalse(IntegrationsSettingsCopy.isConflict(.installed))
        XCTAssertFalse(IntegrationsSettingsCopy.isConflict(.outdated))
        XCTAssertFalse(IntegrationsSettingsCopy.isConflict(.notInstalled))
    }

    // MARK: Failures and files

    func testAnUnreadableFileIsNamedAndNotOverwritten() {
        let error = SettingsFile.Error.unparsable(URL(fileURLWithPath: "/tmp/p7/settings.json"))
        XCTAssertEqual(
            IntegrationsSettingsCopy.failure(error),
            "settings.json isn't valid — Omelette won't overwrite a file it can't read. Fix or move it and try again."
        )
    }

    func testAnotherToolsSettingIsQuoted() {
        XCTAssertEqual(
            IntegrationsSettingsCopy.failure(SettingsFile.Error.conflict("statusLine")),
            "Another tool already owns that setting: statusLine"
        )
    }

    func testAnyOtherErrorIsItsOwnDescription() {
        let error = NSError(domain: "p7", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk full"])
        XCTAssertEqual(IntegrationsSettingsCopy.failure(error), "Disk full")
    }

    /// Ruling S1: the rows' previews are one right-click away, named after 2.x's
    /// disclosure ("What will be written").
    func testTheContextMenuCopiesWhatWillBeWritten() {
        XCTAssertEqual(IntegrationsSettingsCopy.copyPreviewTitle, "Copy what will be written")
        XCTAssertEqual(CommandLineSettingsText.statusLinePreviewTitle, "What will be written")
    }

    func testTheContextMenuOpensTheFileByName() {
        XCTAssertEqual(IntegrationsSettingsCopy.openFileTitle(URL(fileURLWithPath: "/tmp/p7/.claude.json")), "Open .claude.json")
        XCTAssertEqual(IntegrationsSettingsCopy.openFileTitle(URL(fileURLWithPath: "/tmp/p7/config.toml")), "Open config.toml")
    }

    // MARK: Words

    func testTheLong2xCaptionsSurviveAsHelp() {
        XCTAssertEqual(IntegrationsSettingsCopy.statusLineHelp, CommandLineSettingsText.statusLineCaption)
        XCTAssertTrue(IntegrationsSettingsCopy.claudeMCPHelp.contains(CommandLineSettingsText.mcpCaption))
        XCTAssertTrue(IntegrationsSettingsCopy.claudeMCPHelp.contains(CommandLineSettingsText.mcpClaudeCaption))
        XCTAssertEqual(IntegrationsSettingsCopy.codexMCPHelp, CommandLineSettingsText.mcpCodexCaption)
        XCTAssertEqual(IntegrationsSettingsCopy.commandHelp, CommandLineSettingsText.pathCaption)
        XCTAssertTrue(IntegrationsSettingsCopy.claudeHooksHelp.contains("settings.json.omelette-backup"))
        XCTAssertTrue(IntegrationsSettingsCopy.codexHooksHelp.contains("~/.codex/hooks.json"))
        XCTAssertTrue(IntegrationsSettingsCopy.codexNotifyHelp.contains("top-level key"))
        XCTAssertTrue(IntegrationsSettingsCopy.permissionsHelp.contains("after two minutes"))
    }

    func testTheRowsReadAsTheMockup() {
        XCTAssertEqual(IntegrationsSettingsCopy.claudeHeader, "Claude Code")
        XCTAssertEqual(IntegrationsSettingsCopy.codexHeader, "Codex")
        XCTAssertEqual(IntegrationsSettingsCopy.hooksTitle, "Hooks")
        XCTAssertEqual(IntegrationsSettingsCopy.statusLineTitle, "Status line")
        XCTAssertEqual(IntegrationsSettingsCopy.mcpTitle, "MCP server")
        XCTAssertEqual(IntegrationsSettingsCopy.codexNotifyTitle, "Notify for finished turns")
        XCTAssertEqual(IntegrationsSettingsCopy.claudeHooksCaption, "Session id, tool name and folder only, never prompts or files.")
        XCTAssertEqual(IntegrationsSettingsCopy.statusLineCaption, "Session window, reset time, today's cost in Claude Code's status bar.")
        XCTAssertEqual(IntegrationsSettingsCopy.claudeMCPCaption, "Read-only: get_usage, get_agents, get_sessions.")
        XCTAssertEqual(IntegrationsSettingsCopy.codexHooksCaption, "Trust once with /hooks inside Codex.")
        XCTAssertEqual(IntegrationsSettingsCopy.permissionsHeader, "Permissions")
        XCTAssertEqual(IntegrationsSettingsCopy.permissionsTitle, "Answer permission requests from Omelette")
        XCTAssertEqual(
            IntegrationsSettingsCopy.permissionsCaption,
            "Allow / Deny show only while that terminal isn't in front. Unanswered requests go back after 2 minutes."
        )
        XCTAssertEqual(IntegrationsSettingsCopy.commandLineHeader, "Command line")
        XCTAssertEqual(IntegrationsSettingsCopy.commandTitle, "omelette")
        XCTAssertEqual(IntegrationsSettingsCopy.copyPathButton, "Copy PATH line")
        XCTAssertEqual(IntegrationsSettingsCopy.copiedButton, "Copied")
        XCTAssertEqual(IntegrationsSettingsCopy.revealButton, "Reveal in Finder")
        XCTAssertEqual(
            IntegrationsSettingsCopy.commandLineFooter,
            "Add the PATH line to ~/.zshrc, then omelette status works from any terminal."
        )
        XCTAssertEqual(IntegrationsSettingsCopy.copyStatusLineCommand, "Copy Omelette's command")
        XCTAssertEqual(IntegrationsSettingsCopy.copyCodexNotifyLine, "Copy Omelette's line")
    }
}
