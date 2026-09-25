import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "Providers: one row per provider: logo,
/// source, status (connected / not running + last known / off), enable switch, 'Forget
/// last known' inline; … Gemini CLI is gone" (`Settings-Providers.dc.html`), and
/// § Removals (Gemini CLI provider).
final class ProvidersSettingsCopyTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { moment(day: 25, hour: 14, minute: 10) }

    private func session(percent: Double = 21) -> UsageBucket {
        Fixture.bucket(id: "antigravity_gemini_pro", label: "Gemini Pro", percent: percent,
                       resetsAt: moment(day: 25, hour: 13, minute: 0), kind: .session)
    }

    /// Antigravity, closed since 12:50 on 25 Sep, keeping its last reading.
    private func closedAntigravity(readAt: Date? = nil) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", plan: "Antigravity Pro",
            buckets: [session()], state: .notRunning, stateMessage: "Antigravity isn't running",
            at: readAt ?? moment(day: 25, hour: 12, minute: 50)
        )
    }

    private func status(_ service: ServiceSnapshot?, enabled: Bool = true) -> SettingsStatus {
        ProvidersSettingsCopy.status(for: service, isEnabled: enabled, now: now, calendar: calendar, locale: locale)
    }

    // MARK: Rows

    func testTheFourProvidersAreListedInTheMockupsOrder() {
        XCTAssertEqual(ProvidersSettingsCopy.rows(services: []).map(\.id), ["claude", "codex", "antigravity", "grok"])
        XCTAssertEqual(ProvidersSettingsCopy.rows(services: []).map(\.name), ["Claude", "Codex", "Antigravity", "Grok"])
    }

    func testClaudeIsAlwaysOnAndTheOthersHaveASwitch() {
        XCTAssertEqual(ProvidersSettingsCopy.rows(services: []).map(\.hasSwitch), [false, true, true, true])
    }

    func testEachRowSaysWhereItsNumbersComeFrom() {
        XCTAssertEqual(ProvidersSettingsCopy.rows(services: []).map(\.source), [
            "Claude Code sign-in",
            "Local Codex CLI, needs codex login",
            "Running Antigravity app, agy CLI or IDE",
            "Local Grok CLI, grok.com fallback",
        ])
    }

    func testTheIDsAreTheProviders() {
        XCTAssertEqual(ProvidersSettingsCopy.claudeID, ClaudeOAuthProvider.serviceID)
        XCTAssertEqual(ProvidersSettingsCopy.codexID, CodexProvider.serviceID)
        XCTAssertEqual(ProvidersSettingsCopy.antigravityID, "antigravity")
        XCTAssertEqual(ProvidersSettingsCopy.grokID, "grok")
        XCTAssertEqual(ProvidersSettingsCopy.adminID, "anthropic-admin")
    }

    func testGeminiIsNeverListedEvenWhileItStillReports() {
        let gemini = Fixture.snapshot(id: "gemini", displayName: "Gemini")
        XCTAssertFalse(ProvidersSettingsCopy.rows(services: [gemini]).map(\.id).contains("gemini"))
    }

    func testAnAdminAPIOrganisationIsListedAfterThemWithoutASwitch() {
        let admin = Fixture.snapshot(id: "anthropic-admin", displayName: "Anthropic Enterprise", icon: "building.2")
        let rows = ProvidersSettingsCopy.rows(services: [admin])
        XCTAssertEqual(rows.map(\.id), ["claude", "codex", "antigravity", "grok", "anthropic-admin"])
        XCTAssertEqual(rows.last, ProvidersSettingsCopy.Provider(
            id: "anthropic-admin", name: "Anthropic Enterprise", source: "Admin API key, in Advanced",
            sfFallback: "building.2", hasSwitch: false
        ))
    }

    func testAListedProviderThatReportsIsNotListedTwice() {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude")
        XCTAssertEqual(ProvidersSettingsCopy.rows(services: [claude]).filter { $0.id == "claude" }.count, 1)
    }

    // MARK: Status

    func testAConnectedProviderNamesItsPlan() {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Max 20x")
        XCTAssertEqual(status(claude), SettingsStatus(text: "Connected · Max 20x", dot: .ok))
    }

    func testThePlanDropsTheProvidersOwnName() {
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", plan: "Codex Plus")
        XCTAssertEqual(status(codex), SettingsStatus(text: "Connected · Plus", dot: .ok))
    }

    func testAConnectedProviderWithoutAPlanSaysConnected() {
        let grok = Fixture.snapshot(id: "grok", displayName: "Grok", plan: nil)
        XCTAssertEqual(status(grok), SettingsStatus(text: "Connected", dot: .ok))
    }

    func testAClosedAntigravityIsNotRunningWithItsLastKnownTime() {
        XCTAssertEqual(status(closedAntigravity()), SettingsStatus(text: "Not running · last known 12:50", dot: .muted))
    }

    func testAnOlderReadingCarriesItsDay() {
        let line = status(closedAntigravity(readAt: moment(day: 24, hour: 12, minute: 50))).text
        XCTAssertTrue(line.hasPrefix("Not running · last known "), line)
        XCTAssertTrue(line.hasSuffix(", 12:50"), line)
    }

    func testANotRunningProviderWithNothingKeptSaysOnlyThat() {
        let bare = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", buckets: [], state: .notRunning)
        XCTAssertEqual(status(bare), SettingsStatus(text: "Not running", dot: .muted))
    }

    func testASignedOutProviderAsksForSignIn() {
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [], state: .notSignedIn)
        XCTAssertEqual(status(codex), SettingsStatus(text: "Sign in needed", dot: .warning))
    }

    func testAFailingProviderThatKeptItsNumbersSaysErrorAndWhen() {
        let grok = Fixture.snapshot(id: "grok", displayName: "Grok", buckets: [session(percent: 40)],
                                    state: .error, at: moment(day: 25, hour: 12, minute: 50))
        XCTAssertEqual(status(grok), SettingsStatus(text: "Error · last known 12:50", dot: .critical))
    }

    func testASwitchedOffProviderIsOff() {
        XCTAssertEqual(status(nil, enabled: false), SettingsStatus(text: "Off", dot: .muted))
        XCTAssertEqual(status(closedAntigravity(), enabled: false), SettingsStatus(text: "Off", dot: .muted))
    }

    func testAProviderSwitchedOnButNotPolledYetIsChecking() {
        XCTAssertEqual(status(nil), SettingsStatus(text: "Checking…", dot: .muted))
    }

    // MARK: Forget last known

    func testForgetIsOfferedOnlyOnARetainedProvider() {
        XCTAssertTrue(ProvidersSettingsCopy.showsForget(closedAntigravity()))
        XCTAssertFalse(ProvidersSettingsCopy.showsForget(Fixture.snapshot(id: "claude", displayName: "Claude",
                                                                           buckets: [session()])))
        XCTAssertFalse(ProvidersSettingsCopy.showsForget(Fixture.snapshot(id: "grok", displayName: "Grok",
                                                                           buckets: [], state: .error)))
        XCTAssertFalse(ProvidersSettingsCopy.showsForget(nil))
    }

    func testTheForgetLinkReadsAsTheMockupAndExplainsItselfOnHover() {
        XCTAssertEqual(ProvidersSettingsCopy.forgetLink, "Forget last known")
        XCTAssertTrue(ProvidersSettingsCopy.forgetHelp.hasPrefix("Clears the stored reading"), ProvidersSettingsCopy.forgetHelp)
    }

    // MARK: Footer

    func testTheFooterSaysClaudeIsAlwaysOnAndWhenTheLastFetchWas() {
        XCTAssertEqual(
            ProvidersSettingsCopy.footer(fetchedAt: now.addingTimeInterval(-7), now: now),
            "Claude is always on. Last fetch 7s ago. A provider that is closed keeps its last known numbers, dimmed, until you forget them."
        )
    }

    func testLastFetchCountsInTheAppsUnits() {
        XCTAssertEqual(ProvidersSettingsCopy.lastFetch(fetchedAt: now.addingTimeInterval(-3), now: now), "Last fetch just now")
        XCTAssertEqual(ProvidersSettingsCopy.lastFetch(fetchedAt: now.addingTimeInterval(-250), now: now), "Last fetch 4m ago")
        XCTAssertEqual(ProvidersSettingsCopy.lastFetch(fetchedAt: now.addingTimeInterval(-7_300), now: now), "Last fetch 2h ago")
    }

    func testBeforeTheFirstFetchThereIsNothingToDate() {
        XCTAssertEqual(
            ProvidersSettingsCopy.lastFetch(fetchedAt: Date(timeIntervalSince1970: 0), now: now),
            "Nothing fetched yet"
        )
    }

    func testThePollsErrorIsAnAmberLineUnderTheList() {
        XCTAssertEqual(
            ProvidersSettingsCopy.lastErrorNote(" HTTP 500 "),
            SettingsCaption(text: "HTTP 500", token: .warning)
        )
        XCTAssertNil(ProvidersSettingsCopy.lastErrorNote(nil))
        XCTAssertNil(ProvidersSettingsCopy.lastErrorNote("  "))
    }

    // MARK: Row parts

    func testTheLogoIsTheProvidersAtTwentyEightPoints() {
        let codex = ProvidersSettingsCopy.listed[1]
        XCTAssertEqual(
            ProvidersSettingsCopy.logo(for: codex, service: nil),
            SettingsLogo(serviceID: "codex", sfFallback: "terminal", boxSize: 28, glyphSize: 20)
        )
        let reporting = Fixture.snapshot(id: "codex", displayName: "Codex", icon: "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(
            ProvidersSettingsCopy.logo(for: codex, service: reporting).sfFallback,
            "chevron.left.forwardslash.chevron.right"
        )
    }

    func testTheSwitchIsNamedForVoiceOver() {
        XCTAssertEqual(ProvidersSettingsCopy.switchLabel("Grok"), "Show Grok")
    }
}
