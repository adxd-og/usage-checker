import XCTest
@testable import Omelette

/// Independent verification of P7's tab copy enums against the liquid-glass spec and
/// the `Settings-*.dc.html` mockups (read directly, not through the executor's own
/// `ProvidersSettingsCopyTests` / `MenuBarSettingsCopyTests` / `IntegrationsSettingsCopyTests`).
final class SettingsTabCopyVerificationTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    // MARK: - ProvidersSettingsCopy.status (spec § Settings: "status is a dot + text")

    func testOffOverridesTheServicesOwnState() {
        let service = Fixture.snapshot(plan: "Claude Max 20x", state: .ok)
        let status = ProvidersSettingsCopy.status(for: service, isEnabled: false, now: moment(day: 25, hour: 12, minute: 0))
        XCTAssertEqual(status.text, "Off")
        XCTAssertEqual(status.dot, .muted)
    }

    func testANilServiceThatIsEnabledReadsChecking() {
        let status = ProvidersSettingsCopy.status(for: nil, isEnabled: true, now: moment(day: 25, hour: 12, minute: 0))
        XCTAssertEqual(status.text, "Checking…")
        XCTAssertEqual(status.dot, .muted)
    }

    func testAConnectedProviderShowsItsPlanAfterTheDisplayNamePrefixIsDropped() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Claude Max 20x", state: .ok)
        let status = ProvidersSettingsCopy.status(for: service, isEnabled: true, now: moment(day: 25, hour: 12, minute: 0))
        XCTAssertEqual(status.text, "Connected · Max 20x")
        XCTAssertEqual(status.dot, .ok)
    }

    /// D8 / D13: a retained provider (closed, but still carrying a last-known reading)
    /// reads "Not running · last known HH:mm" — the spec's exact words, lowercase "last known".
    func testARetainedAntigravityReadsNotRunningWithALastKnownStamp() {
        let service = Fixture.snapshot(
            id: "antigravity",
            displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini_pro", label: "Gemini Pro", percent: 21)],
            state: .notRunning,
            at: moment(day: 25, hour: 12, minute: 50)
        )
        let status = ProvidersSettingsCopy.status(
            for: service, isEnabled: true,
            now: moment(day: 25, hour: 14, minute: 10), calendar: calendar, locale: locale
        )
        XCTAssertEqual(status.text, "Not running · last known 12:50")
        XCTAssertEqual(status.dot, .muted)
    }

    private func closedAntigravity() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini_pro", percent: 21)],
            state: .notRunning, at: moment(day: 25, hour: 12, minute: 50)
        )
    }

    /// A provider that has never reported (no buckets, not carried over) is not
    /// retained, so its "not running" state carries no stamp.
    func testANeverPolledProviderThatIsNotRunningCarriesNoStamp() {
        let service = Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [], state: .notRunning)
        let status = ProvidersSettingsCopy.status(for: service, isEnabled: true, now: moment(day: 25, hour: 12, minute: 0))
        XCTAssertEqual(status.text, "Not running")
        XCTAssertFalse(status.text.contains("last known"))
    }

    func testSignInNeededIsWarningAndErrorIsCritical() {
        let signIn = Fixture.snapshot(id: "codex", state: .notSignedIn)
        let error = Fixture.snapshot(id: "grok", state: .error)
        let now = moment(day: 25, hour: 12, minute: 0)
        XCTAssertEqual(ProvidersSettingsCopy.status(for: signIn, isEnabled: true, now: now).text, "Sign in needed")
        XCTAssertEqual(ProvidersSettingsCopy.status(for: signIn, isEnabled: true, now: now).dot, .warning)
        XCTAssertEqual(ProvidersSettingsCopy.status(for: error, isEnabled: true, now: now).text, "Error")
        XCTAssertEqual(ProvidersSettingsCopy.status(for: error, isEnabled: true, now: now).dot, .critical)
    }

    // MARK: - ProvidersSettingsCopy.rows / showsForget (D8)

    /// D12: the four mocked rows appear in the mockup's order even with no poll yet,
    /// and an extra service the poll returned (the Admin API organisation) is appended
    /// after them, without a switch.
    func testTheFourListedRowsComeFirstInOrderThenAnyOtherService() {
        let rows = ProvidersSettingsCopy.rows(services: [Fixture.snapshot(id: "anthropic-admin", displayName: "Admin API")])
        XCTAssertEqual(rows.map(\.id), ["claude", "codex", "antigravity", "grok", "anthropic-admin"])
        XCTAssertEqual(rows.map(\.hasSwitch), [false, true, true, true, false])
    }

    /// D8: "'Forget last known' shows on a retained provider only." A live provider
    /// with numbers, and a provider with no numbers at all, offer nothing to forget.
    func testForgetShowsOnlyOnARetainedProvider() {
        XCTAssertTrue(ProvidersSettingsCopy.showsForget(closedAntigravity()))
        XCTAssertFalse(ProvidersSettingsCopy.showsForget(Fixture.snapshot(id: "claude", state: .ok)))
        XCTAssertFalse(ProvidersSettingsCopy.showsForget(nil))
    }

    // MARK: - MenuBarSettingsCopy.canHide (spec: "The last visible one can't be hidden")

    private func service(_ id: String) -> ServiceSnapshot {
        Fixture.snapshot(id: id, buckets: [Fixture.bucket(id: "\(id)_session", percent: 10)])
    }

    func testBothProvidersCanBeHiddenWhileTwoAreShown() {
        let candidates = [service("claude"), service("codex")]
        XCTAssertTrue(MenuBarSettingsCopy.canHide("claude", candidates: candidates, hidden: []))
        XCTAssertTrue(MenuBarSettingsCopy.canHide("codex", candidates: candidates, hidden: []))
    }

    func testTheLastVisibleProviderCannotBeHidden() {
        let candidates = [service("claude"), service("codex")]
        // codex is already hidden, so claude is the only one left showing.
        XCTAssertFalse(MenuBarSettingsCopy.canHide("claude", candidates: candidates, hidden: ["codex"]))
        // codex itself, already hidden, is not blocked from being re-shown.
        XCTAssertTrue(MenuBarSettingsCopy.canHide("codex", candidates: candidates, hidden: ["codex"]))
    }

    func testASoleCandidateCanNeverBeHidden() {
        let candidates = [service("claude")]
        XCTAssertFalse(MenuBarSettingsCopy.canHide("claude", candidates: candidates, hidden: []))
    }

    // MARK: - IntegrationsSettingsCopy (mockup `Settings-Integrations.dc.html`)

    /// Row titles and captions read straight from the mockup's markup, independent of
    /// whatever the executor's own tests assert.
    func testSectionAndRowTitlesMatchTheMockupLiterally() {
        XCTAssertEqual(IntegrationsSettingsCopy.claudeHeader, "Claude Code")
        XCTAssertEqual(IntegrationsSettingsCopy.codexHeader, "Codex")
        XCTAssertEqual(IntegrationsSettingsCopy.hooksTitle, "Hooks")
        XCTAssertEqual(IntegrationsSettingsCopy.statusLineTitle, "Status line")
        XCTAssertEqual(IntegrationsSettingsCopy.mcpTitle, "MCP server")
        XCTAssertEqual(IntegrationsSettingsCopy.codexNotifyTitle, "Notify for finished turns")
        XCTAssertEqual(
            IntegrationsSettingsCopy.claudeHooksCaption,
            "Session id, tool name and folder only, never prompts or files."
        )
        XCTAssertEqual(
            IntegrationsSettingsCopy.statusLineCaption,
            "Session window, reset time, today's cost in Claude Code's status bar."
        )
        XCTAssertEqual(IntegrationsSettingsCopy.claudeMCPCaption, "Read-only: get_usage, get_agents, get_sessions.")
        XCTAssertEqual(IntegrationsSettingsCopy.codexHooksCaption, "Trust once with /hooks inside Codex.")
        XCTAssertEqual(
            IntegrationsSettingsCopy.permissionsTitle,
            "Answer permission requests from Omelette"
        )
        XCTAssertEqual(
            IntegrationsSettingsCopy.permissionsCaption,
            "Allow / Deny show only while that terminal isn't in front. Unanswered requests go back after 2 minutes."
        )
        XCTAssertEqual(IntegrationsSettingsCopy.commandLineHeader, "Command line")
        XCTAssertEqual(IntegrationsSettingsCopy.copyPathButton, "Copy PATH line")
        XCTAssertEqual(IntegrationsSettingsCopy.revealButton, "Reveal in Finder")
        XCTAssertEqual(
            IntegrationsSettingsCopy.commandLineFooter,
            "Add the PATH line to ~/.zshrc, then omelette status works from any terminal."
        )
    }

    /// Ruling S1: the removed "What will be written" preview survives as a context-menu
    /// item, "Copy what will be written", built from `CommandLineSettingsText.statusLinePreviewTitle`.
    func testCopyPreviewTitleIsCopyWhatWillBeWritten() {
        XCTAssertEqual(CommandLineSettingsText.statusLinePreviewTitle, "What will be written")
        XCTAssertEqual(IntegrationsSettingsCopy.copyPreviewTitle, "Copy what will be written")
    }

    /// Ruling S2: "Open <file>" is the context menu's own title, built from the file
    /// installers actually write to.
    func testOpenFileTitleNamesTheExactFile() {
        XCTAssertEqual(
            IntegrationsSettingsCopy.openFileTitle(URL(fileURLWithPath: "/Users/tester/.claude/settings.json")),
            "Open settings.json"
        )
        XCTAssertEqual(
            IntegrationsSettingsCopy.openFileTitle(URL(fileURLWithPath: "/Users/tester/.codex/config.toml")),
            "Open config.toml"
        )
    }

    /// `isConflict` gates the "Copy Omelette's command/line" note action: only a
    /// `.conflict` status has anything of Omelette's own to copy.
    func testIsConflictIsTrueOnlyForConflictStatus() {
        XCTAssertTrue(IntegrationsSettingsCopy.isConflict(.conflict("someone else's line")))
        XCTAssertFalse(IntegrationsSettingsCopy.isConflict(.installed))
        XCTAssertFalse(IntegrationsSettingsCopy.isConflict(.notInstalled))
        XCTAssertFalse(IntegrationsSettingsCopy.isConflict(.outdated))
    }
}
