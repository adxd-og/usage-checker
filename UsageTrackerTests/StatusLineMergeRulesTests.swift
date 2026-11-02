import XCTest
@testable import Omelette

/// Claude's session and weekly windows from Claude Code's status line (spec 2026-11-02
/// Claude limits from the status line, § Design › App, Merge): the newest session dated
/// within five minutes, from the default Claude folder, replaces OAuth's two buckets when
/// it is newer than Claude's `fetchedAt`, keeping their label and kind; a window OAuth did
/// not report becomes a bucket under OAuth's own name for it; a window past its reset is
/// ignored; nothing else on the service, and no other service, changes.
final class StatusLineMergeRulesTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private var defaultDir: String { StatusLineMergeRules.defaultConfigDir(home: StatusLineFixture.home) }

    private let oauthSession = Fixture.bucket(
        id: "five_hour", label: "Current session", percent: 20,
        resetsAt: StatusLineFixture.fiveHourResetsAt, kind: .session
    )
    private let oauthWeek = Fixture.bucket(
        id: "seven_day", label: "All models", percent: 40,
        resetsAt: StatusLineFixture.sevenDayResetsAt, kind: .weekly
    )
    private let opus = Fixture.bucket(
        id: "seven_day_opus", label: "Opus only", percent: 12,
        resetsAt: StatusLineFixture.sevenDayResetsAt, kind: .modelSpecific
    )
    private let extra = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 5, utilization: 10)

    /// A window the status line fed: its percent, its reset, its source and the reading's
    /// time; OAuth's label and kind.
    private func fedSession(_ percent: Double, asOf: Date) -> UsageBucket {
        Fixture.bucket(
            id: "five_hour", label: "Current session", percent: percent,
            resetsAt: StatusLineFixture.fiveHourResetsAt, kind: .session, source: .statusLine, asOf: asOf
        )
    }

    private func fedWeek(_ percent: Double, asOf: Date) -> UsageBucket {
        Fixture.bucket(
            id: "seven_day", label: "All models", percent: percent,
            resetsAt: StatusLineFixture.sevenDayResetsAt, kind: .weekly, source: .statusLine, asOf: asOf
        )
    }

    private func window(_ percent: Double, resetsAt: Date = StatusLineFixture.fiveHourResetsAt) -> StatusLineInput.RateLimits.Window {
        StatusLineInput.RateLimits.Window(usedPercent: percent, resetsAt: resetsAt)
    }

    private func session(
        _ id: String = StatusLineFixture.sessionID,
        asOf: Date?,
        fiveHour: StatusLineInput.RateLimits.Window? = StatusLineFixture.fiveHour,
        sevenDay: StatusLineInput.RateLimits.Window? = StatusLineFixture.sevenDay,
        configDir: String = StatusLineFixture.configDir
    ) -> StatusLineFreshnessRules.Session {
        StatusLineFreshnessRules.Session(
            sessionID: id,
            promptID: StatusLineFixture.promptID,
            totalAPIDurationMs: 18_250,
            asOf: asOf,
            writtenAt: asOf ?? now,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            configDir: configDir
        )
    }

    private func claude(
        buckets: [UsageBucket]? = nil,
        state: ServiceState = .ok,
        stateMessage: String? = nil,
        fetchedAt: Date
    ) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: buckets ?? [oauthSession, oauthWeek, opus, Fixture.cloudCredits],
            extraUsage: extra, state: state, stateMessage: stateMessage, at: fetchedAt
        )
    }

    private func codex() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)], at: now
        )
    }

    private func poll(_ services: [ServiceSnapshot]) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: now, isStale: false, lastError: nil)
    }

    private func merged(
        _ services: [ServiceSnapshot], _ sessions: [StatusLineFreshnessRules.Session]
    ) -> StatusLineMergeRules.Result {
        StatusLineMergeRules.merge(poll(services), sessions: sessions, defaultConfigDir: defaultDir, now: now)
    }

    func testANewerReadingReplacesTheTwoCoreWindowsAndNothingElse() throws {
        let oauth = claude(fetchedAt: ago(120))

        let result = merged([oauth], [session(asOf: ago(60))])

        XCTAssertTrue(result.applied)
        let shown = try XCTUnwrap(result.snapshot.services.first)
        XCTAssertEqual(shown.buckets, [fedSession(23.5, asOf: ago(60)), fedWeek(41.2, asOf: ago(60)), opus, Fixture.cloudCredits])
        XCTAssertEqual(shown.fetchedAt, oauth.fetchedAt, "the windows OAuth alone reports still date from its fetch")
        XCTAssertEqual(shown.extraUsage, extra)
        XCTAssertEqual(shown.plan, "Max 20x")
        XCTAssertEqual(shown.state, .ok)
        XCTAssertEqual(result.snapshot.fetchedAt, now)
    }

    func testAnOAuthReadingAsNewOrNewerKeepsItsNumbers() {
        for fetchedAt in [ago(60), ago(30)] {
            let oauth = poll([claude(fetchedAt: fetchedAt)])

            let result = StatusLineMergeRules.merge(
                oauth, sessions: [session(asOf: ago(60))], defaultConfigDir: defaultDir, now: now
            )

            XCTAssertFalse(result.applied, "\(fetchedAt)")
            XCTAssertEqual(result.snapshot, oauth, "\(fetchedAt)")
        }
    }

    func testTheBucketKeepsOAuthsLabelKindAndLength() throws {
        let odd = Fixture.bucket(
            id: "five_hour", label: "Session (5h)", percent: 20,
            resetsAt: StatusLineFixture.fiveHourResetsAt, kind: .other, windowLength: 18_000
        )

        let result = merged([claude(buckets: [odd], fetchedAt: ago(120))], [session(asOf: ago(60), sevenDay: nil)])

        let buckets = try XCTUnwrap(result.snapshot.services.first?.buckets)
        XCTAssertEqual(buckets, [Fixture.bucket(
            id: "five_hour", label: "Session (5h)", percent: 23.5,
            resetsAt: StatusLineFixture.fiveHourResetsAt, kind: .other, windowLength: 18_000,
            source: .statusLine, asOf: ago(60)
        )])
    }

    /// OAuth failing with nothing kept: the status line's windows become the buckets, under
    /// the names OAuth gives them, whatever the failed attempt's time — it carried no
    /// numbers to be newer than. The state and its chip stay.
    func testAWindowOAuthDidNotReportBecomesABucketUnderItsStandardName() throws {
        let failing = claude(buckets: [], state: .error, stateMessage: "Rate limited by usage API", fetchedAt: ago(5))

        let result = merged([failing], [session(asOf: ago(60))])

        XCTAssertTrue(result.applied)
        let shown = try XCTUnwrap(result.snapshot.services.first)
        XCTAssertEqual(shown.buckets, [fedSession(23.5, asOf: ago(60)), fedWeek(41.2, asOf: ago(60))])
        XCTAssertEqual(shown.state, .error)
        XCTAssertEqual(shown.stateMessage, "Rate limited by usage API")
        XCTAssertTrue(shown.isRetained, "drawn dimmed with its chip, as any number a failing provider shows")
    }

    func testASignedOutClaudeWithLastKnownNumbersGetsTheNewerWindowsAndStaysDimmed() throws {
        var retained = claude(
            buckets: [oauthSession, oauthWeek, opus], state: .notSignedIn, stateMessage: "Sign in",
            fetchedAt: ago(3 * 3600)
        )
        retained.isCarriedOver = true
        retained.signedOutReason = .expired

        let result = merged([retained], [session(asOf: ago(60))])

        let shown = try XCTUnwrap(result.snapshot.services.first)
        XCTAssertEqual(shown.buckets, [fedSession(23.5, asOf: ago(60)), fedWeek(41.2, asOf: ago(60)), opus])
        XCTAssertEqual(shown.state, .notSignedIn)
        XCTAssertEqual(shown.stateMessage, "Sign in")
        XCTAssertTrue(shown.isCarriedOver)
        XCTAssertEqual(shown.signedOutReason, .expired)
        XCTAssertEqual(shown.fetchedAt, retained.fetchedAt)
        XCTAssertTrue(shown.isRetained)
    }

    func testAWindowOAuthDidNotReportTakesItsPlaceAtTheHead() {
        let onlyOpus = merged([claude(buckets: [opus], fetchedAt: ago(120))], [session(asOf: ago(60))])
        XCTAssertEqual(onlyOpus.snapshot.services.first?.buckets.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])

        let noWeek = merged([claude(buckets: [oauthSession, opus], fetchedAt: ago(120))], [session(asOf: ago(60))])
        XCTAssertEqual(noWeek.snapshot.services.first?.buckets.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
    }

    func testAWindowPastItsResetIsIgnored() throws {
        let oauth = claude(fetchedAt: ago(120))

        let result = merged([oauth], [session(asOf: ago(60), fiveHour: window(99, resetsAt: now))])

        XCTAssertTrue(result.applied)
        let shown = try XCTUnwrap(result.snapshot.services.first)
        XCTAssertEqual(shown.buckets, [oauthSession, fedWeek(41.2, asOf: ago(60)), opus, Fixture.cloudCredits], "OAuth's session window stays")

        let nothingLive = merged(
            [oauth],
            [session(asOf: ago(60), fiveHour: window(99, resetsAt: now), sevenDay: window(99, resetsAt: ago(1)))]
        )
        XCTAssertFalse(nothingLive.applied)
        XCTAssertEqual(nothingLive.snapshot, poll([oauth]))
    }

    func testTheNewestSessionWins() {
        let older = session("1111", asOf: ago(200), fiveHour: window(30))
        let newest = session("2222", asOf: ago(100), fiveHour: window(35))

        for sessions in [[older, newest], [newest, older]] {
            let result = merged([claude(fetchedAt: ago(600))], sessions)
            XCTAssertEqual(result.snapshot.services.first?.buckets.first?.utilization, 35)
        }
    }

    func testOnlyAReadingDatedWithinFiveMinutesOfNowIsUsed() {
        let oauth = claude(fetchedAt: ago(3600))

        XCTAssertTrue(merged([oauth], [session(asOf: ago(300))]).applied, "five minutes is still fresh")
        XCTAssertFalse(merged([oauth], [session(asOf: ago(301))]).applied)
        XCTAssertFalse(
            merged([oauth], [session(asOf: ago(-301))]).applied,
            "a reading dated more than five minutes ahead (a clock that moved back) is not fresh either"
        )
    }

    func testAReadingFromAnotherClaudeFolderIsNotApplied() {
        XCTAssertEqual(defaultDir, StatusLineFixture.configDir, "the fixture's folder is the default one")
        let oauth = claude(fetchedAt: ago(120))

        let result = merged([oauth], [session(asOf: ago(60), configDir: "/tmp/work-claude")])

        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.snapshot, poll([oauth]))
    }

    func testAnUndatedSessionIsNeverApplied() {
        let failing = claude(buckets: [], state: .error, fetchedAt: ago(5))

        let result = merged([failing], [session(asOf: nil)])

        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.snapshot, poll([failing]))
    }

    /// Claude switched off is not in the poll: the status line does not bring it back.
    func testWithClaudeOffNothingIsAdded() {
        let result = merged([codex()], [session(asOf: ago(60))])

        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.snapshot, poll([codex()]))
    }

    func testOtherProvidersAreUntouched() {
        let result = merged([claude(fetchedAt: ago(120)), codex()], [session(asOf: ago(60))])

        XCTAssertEqual(result.snapshot.services.map(\.id), ["claude", "codex"])
        XCTAssertEqual(result.snapshot.services.last, codex())
    }

    func testAWindowOAuthDidNotReportIsCalledWhatOAuthCallsIt() throws {
        XCTAssertEqual(ClaudeOAuthProvider.knownWindow(id: "five_hour")?.label, "Current session")
        XCTAssertEqual(ClaudeOAuthProvider.knownWindow(id: "five_hour")?.kind, .session)
        XCTAssertEqual(ClaudeOAuthProvider.knownWindow(id: "seven_day")?.label, "All models")
        XCTAssertEqual(ClaudeOAuthProvider.knownWindow(id: "seven_day")?.kind, .weekly)
        XCTAssertNil(ClaudeOAuthProvider.knownWindow(id: "spend_limit"))

        let fromOAuth = try ClaudeOAuthProvider.usage(fromPayload: Data(Fixture.cloudCreditsPayload.utf8)).buckets
        XCTAssertEqual(fromOAuth.first { $0.id == "five_hour" }?.label, ClaudeOAuthProvider.knownWindow(id: "five_hour")?.label)
        XCTAssertEqual(fromOAuth.first { $0.id == "seven_day" }?.kind, ClaudeOAuthProvider.knownWindow(id: "seven_day")?.kind)
    }
}
