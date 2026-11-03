import XCTest
@testable import Omelette

/// Verification of the merge (spec 2026-11-02 Claude limits from the status line,
/// § Design › App, Merge) and of what the poll shows once it ran (`AppState.shownAfterPoll`,
/// `statusLineRemerged`). Fixed epoch, no disk.
final class StatusLineMergeVerificationTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    private var dir: String { StatusLineMergeRules.defaultConfigDir(home: StatusLineFixture.home) }

    private let resetS = StatusLineFixture.fiveHourResetsAt
    private let resetW = StatusLineFixture.sevenDayResetsAt

    private func win(_ p: Double, _ reset: Date? = nil) -> StatusLineInput.RateLimits.Window {
        StatusLineInput.RateLimits.Window(usedPercent: p, resetsAt: reset ?? resetS)
    }

    private func session(
        _ id: String, asOf: Date?, five: Double? = 50, seven: Double? = 60,
        fiveReset: Date? = nil, configDir: String? = nil
    ) -> StatusLineFreshnessRules.Session {
        StatusLineFreshnessRules.Session(
            sessionID: id, promptID: nil, totalAPIDurationMs: 1, asOf: asOf, writtenAt: asOf ?? now,
            fiveHour: five.map { win($0, fiveReset) },
            sevenDay: seven.map { win($0, resetW) },
            configDir: configDir ?? dir
        )
    }

    private func claude(
        _ buckets: [UsageBucket]? = nil, state: ServiceState = .ok, at fetched: Date
    ) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: buckets ?? [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 20, resetsAt: resetS, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 40, resetsAt: resetW, kind: .weekly),
            ],
            state: state, at: fetched
        )
    }

    private func merge(_ services: [ServiceSnapshot], _ sessions: [StatusLineFreshnessRules.Session]) -> StatusLineMergeRules.Result {
        StatusLineMergeRules.merge(
            UsageSnapshot(services: services, fetchedAt: now, isStale: false, lastError: nil),
            sessions: sessions, defaultConfigDir: dir, now: now
        )
    }

    private func percents(_ r: StatusLineMergeRules.Result) -> [Double] {
        r.snapshot.services.first { $0.id == "claude" }?.buckets.map(\.utilization) ?? []
    }

    // MARK: - Which session wins

    /// "Within 5 min" is inclusive at 300 s and either way round.
    func testTheFiveMinuteEdgeIsInclusiveBothWays() {
        let oauth = claude(at: ago(3600))
        XCTAssertTrue(merge([oauth], [session("a", asOf: ago(300))]).applied)
        XCTAssertFalse(merge([oauth], [session("a", asOf: ago(301))]).applied)
        XCTAssertTrue(merge([oauth], [session("a", asOf: now.addingTimeInterval(300))]).applied, "dated ahead, but within")
        XCTAssertFalse(merge([oauth], [session("a", asOf: now.addingTimeInterval(301))]).applied, "dated too far ahead (clock moved back)")
    }

    func testTheNewestOfSeveralSessionsWinsWhateverTheOrder() {
        let oauth = claude(at: ago(3600))
        let old = session("a", asOf: ago(200), five: 11, seven: 12)
        let new = session("b", asOf: ago(100), five: 55, seven: 66)
        XCTAssertEqual(percents(merge([oauth], [old, new])), [55, 66])
        XCTAssertEqual(percents(merge([oauth], [new, old])), [55, 66])
    }

    func testATieOnTimeKeepsTheFirstSessionGiven() {
        let oauth = claude(at: ago(3600))
        let a = session("a", asOf: ago(100), five: 11, seven: 12)
        let b = session("b", asOf: ago(100), five: 55, seven: 66)
        XCTAssertEqual(percents(merge([oauth], [a, b])), [11, 12])
        XCTAssertEqual(percents(merge([oauth], [b, a])), [55, 66])
    }

    /// A newer session from another Claude folder never shadows an older default one.
    func testANewerSessionFromAnotherFolderDoesNotShadowTheDefaultOne() {
        let oauth = claude(at: ago(3600))
        let other = session("other", asOf: ago(10), five: 99, seven: 99, configDir: "/tmp/elsewhere/.claude")
        let mine = session("mine", asOf: ago(200), five: 30, seven: 35)
        XCTAssertEqual(percents(merge([oauth], [other, mine])), [30, 35])
        XCTAssertFalse(merge([oauth], [other]).applied)
    }

    /// An undated session newer in `writtenAt` never shadows a dated one.
    func testAnUndatedSessionDoesNotShadowADatedOne() {
        let oauth = claude(at: ago(3600))
        let undated = session("u", asOf: nil, five: 99, seven: 99)
        let dated = session("d", asOf: ago(100), five: 30, seven: 35)
        XCTAssertEqual(percents(merge([oauth], [undated, dated])), [30, 35])
    }

    /// The default folder is spelled the way the CLI spells it, whatever the shape of the
    /// home URL or of `CLAUDE_CONFIG_DIR`.
    func testTheDefaultFolderIsSpelledAsTheCLISpellsIt() {
        let home = URL(fileURLWithPath: "/tmp/StatusLineVerification-home/", isDirectory: true)
        let app = StatusLineMergeRules.defaultConfigDir(home: home)
        XCTAssertEqual(app, "/tmp/StatusLineVerification-home/.claude")
        let cli = StatusLineDrop.configDir(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/StatusLineVerification-home/.claude/"], home: home
        )
        XCTAssertEqual(cli, app, "an explicit CLAUDE_CONFIG_DIR pointing at the default is the default")
    }

    // MARK: - Which windows, and over what

    /// A window past its reset (also exactly at it) is not applied; the live one is.
    func testOnlyTheLiveWindowIsApplied() throws {
        let oauth = claude(at: ago(3600))
        let r = merge([oauth], [session("a", asOf: ago(60), five: 80, seven: 90, fiveReset: now)])
        XCTAssertTrue(r.applied)
        let buckets = try XCTUnwrap(r.snapshot.services.first?.buckets)
        XCTAssertEqual(buckets.map(\.utilization), [20, 90], "the session window is OAuth's own, untouched")
        XCTAssertEqual(buckets.map(\.source), [nil, .statusLine])
        XCTAssertEqual(buckets[0], oauth.buckets[0])
    }

    func testBothWindowsPastTheirResetAppliesNothing() {
        let oauth = claude(at: ago(3600))
        var s = session("a", asOf: ago(60), five: 80, seven: 90, fiveReset: now)
        s = StatusLineFreshnessRules.Session(
            sessionID: s.sessionID, promptID: nil, totalAPIDurationMs: 1, asOf: s.asOf, writtenAt: s.writtenAt,
            fiveHour: s.fiveHour, sevenDay: win(90, ago(1)), configDir: s.configDir
        )
        let r = merge([oauth], [s])
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.snapshot.services, [oauth])
    }

    /// A session carrying only the weekly window leaves OAuth's session window alone.
    func testASessionWithOneWindowFeedsOnlyThatWindow() {
        let r = merge([claude(at: ago(3600))], [session("a", asOf: ago(60), five: nil, seven: 77)])
        XCTAssertEqual(percents(r), [20, 77])
    }

    /// Strictly newer than Claude's fetch: a second older keeps OAuth, a second newer feeds.
    func testItReplacesOnlyWhatIsStrictlyNewerThanTheFetch() {
        let s = session("a", asOf: ago(60))
        XCTAssertEqual(percents(merge([claude(at: ago(59))], [s])), [20, 40])
        XCTAssertEqual(percents(merge([claude(at: ago(60))], [s])), [20, 40])
        XCTAssertEqual(percents(merge([claude(at: ago(61))], [s])), [50, 60])
    }

    /// The merge changes nothing outside the two buckets: other services in their place
    /// (Claude not first), the snapshot's own fetchedAt / isStale / lastError, and
    /// everything else on the Claude service.
    func testNothingOutsideTheTwoBucketsMoves() throws {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 5, utilization: 10)
        let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, resetsAt: resetW, kind: .modelSpecific)
        var oauth = ServiceSnapshot(
            id: "claude", displayName: "Claude", icon: "sparkles", plan: "Max 20x", accountLabel: "me",
            buckets: claude(at: now).buckets + [opus, Fixture.cloudCredits], extraUsage: extra, weekCost: 4.2,
            state: .error, stateMessage: "Rate limited by usage API", fetchedAt: ago(3600)
        )
        oauth.retryAfter = 90
        oauth.isCarriedOver = true
        oauth.signedOutReason = .notFound
        let codex = Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Plus",
            buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)], at: now
        )
        let before = UsageSnapshot(services: [codex, oauth], fetchedAt: ago(7), isStale: true, lastError: "boom")

        let r = StatusLineMergeRules.merge(before, sessions: [session("a", asOf: ago(60))], defaultConfigDir: dir, now: now)

        XCTAssertTrue(r.applied)
        XCTAssertEqual(r.snapshot.services.map(\.id), ["codex", "claude"])
        XCTAssertEqual(r.snapshot.services[0], codex)
        XCTAssertEqual(r.snapshot.fetchedAt, ago(7))
        XCTAssertTrue(r.snapshot.isStale)
        XCTAssertEqual(r.snapshot.lastError, "boom")
        let after = r.snapshot.services[1]
        XCTAssertEqual(after.buckets.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "iguana_necktie"])
        XCTAssertEqual(after.buckets[2], opus)
        XCTAssertEqual(after.buckets[3], Fixture.cloudCredits)
        XCTAssertEqual(after.extraUsage, extra)
        XCTAssertEqual(after.weekCost, 4.2)
        XCTAssertEqual(after.state, .error)
        XCTAssertEqual(after.stateMessage, "Rate limited by usage API")
        XCTAssertEqual(after.retryAfter, 90)
        XCTAssertTrue(after.isCarriedOver)
        XCTAssertEqual(after.signedOutReason, .notFound)
        XCTAssertEqual(after.fetchedAt, ago(3600), "fetchedAt stays the OAuth comparison point")
        XCTAssertEqual(after.accountLabel, "me")
        XCTAssertEqual(after.plan, "Max 20x")
    }

    /// A windowLength OAuth knows survives the replacement.
    func testTheReplacedBucketKeepsItsWindowLength() throws {
        let five = Fixture.bucket(
            id: "five_hour", label: "Current session", percent: 20, resetsAt: resetS, kind: .session, windowLength: 18_000
        )
        let r = merge([claude([five], at: ago(3600))], [session("a", asOf: ago(60))])
        let b = try XCTUnwrap(r.snapshot.services.first?.buckets.first { $0.id == "five_hour" })
        XCTAssertEqual(b.windowLength, 18_000)
        XCTAssertEqual(b.label, "Current session")
        XCTAssertEqual(b.utilization, 50)
        XCTAssertEqual(b.resetsAt, resetS)
        XCTAssertEqual(b.asOf, ago(60))
    }

    // MARK: - What the poll shows

    private func failing(_ state: ServiceState, message: String, reason: SignedOutReason? = nil) -> ServiceSnapshot {
        var s = Fixture.snapshot(id: "claude", displayName: "Claude", plan: nil, buckets: [], state: state, stateMessage: message, at: now)
        s.retryAfter = 120
        s.signedOutReason = reason
        return s
    }

    private func stored() -> [String: LastKnownService] {
        let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, resetsAt: resetW, kind: .modelSpecific)
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 5, utilization: 10)
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: claude(at: now).buckets + [opus, Fixture.cloudCredits], extraUsage: extra, at: ago(3 * 3600)
        )
        return ["claude": LastKnownService(from: service, order: 0)]
    }

    /// A signed-out Claude (and a rate-limited one) fed by the status line keeps OAuth's
    /// state, message, chip inputs and backoff, and its last-known model windows.
    func testAFailedClaudeFedByTheStatusLineKeepsOAuthsStateAndItsModelWindows() throws {
        for (state, message, reason) in [
            (ServiceState.notSignedIn, "Not signed in", SignedOutReason.notFound as SignedOutReason?),
            (.error, "Rate limited by usage API", nil),
        ] {
            let failed = failing(state, message: message, reason: reason)
            let r = AppState.shownAfterPoll(
                previous: .empty,
                next: UsageSnapshot(services: [failed], fetchedAt: now, isStale: false, lastError: nil),
                stored: stored(), statusLine: [session("a", asOf: ago(60))], defaultConfigDir: dir, now: now
            )
            XCTAssertTrue(r.applied)
            let c = try XCTUnwrap(r.snapshot.services.first)
            XCTAssertEqual(c.state, state)
            XCTAssertEqual(c.stateMessage, message)
            XCTAssertEqual(c.retryAfter, 120)
            XCTAssertEqual(c.signedOutReason, reason)
            XCTAssertTrue(c.isRetained)
            XCTAssertTrue(c.isCarriedOver)
            XCTAssertEqual(c.fetchedAt, ago(3 * 3600), "OAuth's last-good time")
            XCTAssertEqual(c.buckets.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "iguana_necktie"])
            XCTAssertEqual(c.buckets.map(\.utilization).prefix(2), [50, 60])
            XCTAssertEqual(c.buckets[2].utilization, 12)
            XCTAssertEqual(c.buckets[2].source, nil)
            XCTAssertEqual(c.extraUsage?.usedCredits, 5)
            XCTAssertTrue(r.snapshot.isStale)
        }
    }

    /// A healthy Codex beside a failed Claude: the snapshot is not stale, and Codex is
    /// untouched by the merge.
    func testAHealthyNeighbourStaysHealthyAndUntouched() throws {
        let codex = Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Plus",
            buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)], at: now
        )
        let r = AppState.shownAfterPoll(
            previous: .empty,
            next: UsageSnapshot(services: [failing(.error, message: "x"), codex], fetchedAt: now, isStale: false, lastError: nil),
            stored: stored(), statusLine: [session("a", asOf: ago(60))], defaultConfigDir: dir, now: now
        )
        XCTAssertFalse(r.snapshot.isStale)
        XCTAssertEqual(r.snapshot.fetchedAt, now)
        XCTAssertEqual(r.snapshot.services.last, codex)
    }

    /// With Claude not in the poll at all (switched off) a fresh reading adds nothing, and
    /// the neighbours are as they were.
    func testClaudeSwitchedOffStaysOffWhateverTheStatusLineSays() {
        let codex = Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Plus",
            buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)], at: now
        )
        let r = AppState.shownAfterPoll(
            previous: .empty,
            next: UsageSnapshot(services: [codex], fetchedAt: now, isStale: false, lastError: nil),
            stored: stored(), statusLine: [session("a", asOf: ago(60))], defaultConfigDir: dir, now: now
        )
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.snapshot.services, [codex])
    }

    /// A re-merge with a reading older than the OAuth numbers on screen, or dated beyond
    /// five minutes, changes nothing (nil).
    func testARemergeWithAnOlderReadingChangesNothing() throws {
        let onScreen = UsageSnapshot(services: [claude(at: ago(30))], fetchedAt: ago(30), isStale: false, lastError: nil)
        XCTAssertNil(AppState.statusLineRemerged(onScreen, sessions: [session("a", asOf: ago(60))], defaultConfigDir: dir, now: now))
        XCTAssertNil(AppState.statusLineRemerged(onScreen, sessions: [session("c", asOf: ago(7200))], defaultConfigDir: dir, now: now))
        let fed = try XCTUnwrap(AppState.statusLineRemerged(onScreen, sessions: [session("a", asOf: ago(10))], defaultConfigDir: dir, now: now))
        XCTAssertEqual(percents(fed), [50, 60])
    }
}
