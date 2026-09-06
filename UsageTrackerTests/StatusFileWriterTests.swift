import XCTest
@testable import Omelette

/// Everything `status.json` says, decided without a disk. The actor at the end of the
/// file gets two tests of its own — that it writes, and that it refuses to write twice
/// in a second — and every other rule is `build`, which is pure.
final class StatusFileWriterTests: XCTestCase {
    private var directory: URL!

    /// 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func claude(
        buckets: [UsageBucket] = [],
        weekCost: Double? = nil,
        state: ServiceState = .ok,
        extraUsage: ExtraUsage? = nil,
        plan: String? = "Max 5x"
    ) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: plan,
            buckets: buckets, extraUsage: extraUsage, weekCost: weekCost,
            state: state, at: now
        )
    }

    // MARK: - build

    func testAServiceBecomesItsWindowsCostsAndPlan() {
        let session = Fixture.bucket(
            id: "five_hour", label: "Session", percent: 42,
            resetsAt: now.addingTimeInterval(100 * 60), kind: .session
        )
        let snapshot = StatusFileWriter.build(
            services: [claude(buckets: [session])],
            costs: ["claude": .init(todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567)],
            agents: .none,
            now: now
        )

        XCTAssertEqual(snapshot.version, StatusSnapshot.currentVersion)
        XCTAssertEqual(snapshot.updatedAt, now)
        let service = snapshot.services.first
        XCTAssertEqual(service?.id, "claude")
        XCTAssertEqual(service?.name, "Claude")
        XCTAssertEqual(service?.state, "ok")
        XCTAssertEqual(service?.plan, "Max 5x")
        XCTAssertEqual(service?.retained, false)
        XCTAssertNil(service?.retainedAt)
        XCTAssertEqual(service?.windows.map(\.id), ["five_hour"])
        XCTAssertEqual(service?.windows.first?.label, "Session")
        XCTAssertEqual(service?.windows.first?.percent, 42)
        XCTAssertEqual(service?.windows.first?.kind, "session")
        XCTAssertEqual(service?.windows.first?.resetsAt, now.addingTimeInterval(100 * 60))
        XCTAssertEqual(service?.todayCost, 4.2)
        XCTAssertEqual(service?.weekCost, 31.7)
        XCTAssertEqual(service?.todayTokens, 1_234_567)
        XCTAssertEqual(service?.apiEquivalent, true, "a subscription's dollars are list-price equivalents")
    }

    func testAnUnknownResetBecomesNoResetAtAll() {
        // `.distantFuture` is how the app spells "the provider didn't say"; a CLI that
        // printed "resets in 3653 days" would be quoting a placeholder at the user.
        let snapshot = StatusFileWriter.build(
            services: [claude(buckets: [Fixture.bucket(id: "weekly", percent: 18, kind: .weekly)])],
            costs: [:], agents: .none, now: now
        )
        XCTAssertNil(snapshot.services.first?.windows.first?.resetsAt)
    }

    func testASpendLimitIsAWindowLikeTheWidgetMakesItOne() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 100, usedCredits: 12, utilization: 12)
        let snapshot = StatusFileWriter.build(
            services: [claude(buckets: [], extraUsage: extra, plan: "Claude Enterprise")],
            costs: [:], agents: .none, now: now
        )

        let window = snapshot.services.first?.windows.first
        XCTAssertEqual(window?.id, "extra_usage")
        XCTAssertEqual(window?.label, "Spend limit")
        XCTAssertEqual(window?.percent, 12)
        XCTAssertEqual(window?.kind, "other")
    }

    func testADisabledSpendLimitIsNotAWindow() {
        let extra = ExtraUsage(isEnabled: false, monthlyLimit: 100, usedCredits: 0, utilization: 0)
        let snapshot = StatusFileWriter.build(
            services: [claude(buckets: [], extraUsage: extra)], costs: [:], agents: .none, now: now
        )
        XCTAssertTrue(snapshot.services.first?.windows.isEmpty == true)
    }

    func testRetainedNumbersCarryTheirStamp() {
        let stale = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: .notRunning, at: now.addingTimeInterval(-3600)
        )
        let snapshot = StatusFileWriter.build(services: [stale], costs: [:], agents: .none, now: now)

        XCTAssertEqual(snapshot.services.first?.retained, true)
        XCTAssertEqual(snapshot.services.first?.retainedAt, now.addingTimeInterval(-3600))
        XCTAssertEqual(snapshot.services.first?.state, "notRunning")
    }

    func testAFailedServiceWithNothingToShowIsStillInTheFile() {
        // The widget drops it — there is nothing to draw. The CLI prints "Sign in
        // needed", which is the whole answer to "why is Codex missing?".
        let snapshot = StatusFileWriter.build(
            services: [Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn, at: now)],
            costs: [:], agents: .none, now: now
        )
        XCTAssertEqual(snapshot.services.map(\.id), ["codex"])
        XCTAssertEqual(snapshot.services.first?.state, "notSignedIn")
        XCTAssertNil(snapshot.services.first?.apiEquivalent, "no dollars, nothing to qualify")
    }

    // MARK: - Pay as you go

    func testPayAsYouGoDollarsAreNotApiEquivalent() {
        let payg = claude(buckets: [], weekCost: 31.7, plan: "Claude Enterprise")
        XCTAssertTrue(StatusFileWriter.isPayAsYouGo(payg))

        let snapshot = StatusFileWriter.build(services: [payg], costs: [:], agents: .none, now: now)
        XCTAssertEqual(snapshot.services.first?.apiEquivalent, false)
        XCTAssertEqual(snapshot.services.first?.weekCost, 31.7)
    }

    func testTheSyntheticBudgetBucketDoesNotMakeAnAccountASubscription() {
        // AppState gives a windowless account a "Weekly budget" bucket so the whole
        // percentage UI works. It is Omelette's own invention, not a reported window,
        // so it must not flip the account back to "API-equivalent".
        let budget = Fixture.bucket(
            id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget", percent: 31, kind: .weekly
        )
        let payg = claude(buckets: [budget], weekCost: 31.7)

        XCTAssertTrue(StatusFileWriter.isPayAsYouGo(payg))
        let snapshot = StatusFileWriter.build(services: [payg], costs: [:], agents: .none, now: now)
        XCTAssertEqual(snapshot.services.first?.apiEquivalent, false)
    }

    func testARealWindowMakesItASubscription() {
        let real = claude(buckets: [Fixture.bucket(id: "five_hour", percent: 42, kind: .session)], weekCost: 31.7)
        XCTAssertFalse(StatusFileWriter.isPayAsYouGo(real))
    }

    // MARK: - Agents

    func testTheAgentSummaryCountsAndListsSessions() {
        let sessions = [
            Fixture.agentSession(sessionID: "a", projectName: "Usage tracker", state: .needsYou, activity: "Remove build artifacts"),
            Fixture.agentSession(sessionID: "b", projectName: "Orion", state: .working, activity: "Read AppState.swift"),
            Fixture.agentSession(sessionID: "c", projectName: "Orion", state: .working),
            Fixture.agentSession(sessionID: "d", projectName: "Old", state: .idle),
        ]
        let summary = StatusFileWriter.AgentSummary(sessions: sessions)

        XCTAssertEqual(summary.needsYou, 1)
        XCTAssertEqual(summary.working, 2)
        XCTAssertEqual(summary.sessions.count, 4)
        XCTAssertEqual(summary.sessions.first?.project, "Usage tracker")
        XCTAssertEqual(summary.sessions.first?.state, "needsYou")
        XCTAssertEqual(summary.sessions.first?.activity, "Remove build artifacts")
        XCTAssertNil(summary.sessions.last?.activity)
    }

    func testTheSessionListIsCapped() {
        let many = (0..<50).map { Fixture.agentSession(sessionID: "s\($0)", projectName: "P", state: .idle) }
        XCTAssertEqual(StatusFileWriter.AgentSummary(sessions: many).sessions.count, StatusFileWriter.maxSessions)
        XCTAssertEqual(StatusFileWriter.AgentSummary(sessions: many).working, 0)
    }

    // MARK: - Throttle and write

    func testTheThrottleIsTwoSeconds() {
        XCTAssertTrue(StatusFileWriter.shouldWrite(
            lastWriteAt: .distantPast, now: now, minimumInterval: StatusFileWriter.minimumInterval
        ))
        XCTAssertFalse(StatusFileWriter.shouldWrite(
            lastWriteAt: now.addingTimeInterval(-1), now: now, minimumInterval: StatusFileWriter.minimumInterval
        ))
        XCTAssertTrue(StatusFileWriter.shouldWrite(
            lastWriteAt: now.addingTimeInterval(-2), now: now, minimumInterval: StatusFileWriter.minimumInterval
        ))
    }

    func testTheWriteLandsAsReadableJSONWithATrailingNewline() async throws {
        let url = directory.appendingPathComponent("nested/status.json")
        let writer = StatusFileWriter(fileURL: url, minimumInterval: 0)
        let built = StatusFileWriter.build(services: [claude()], costs: [:], agents: .none, now: now)

        let wrote = await writer.write(built, now: now)
        XCTAssertTrue(wrote)

        let data = try XCTUnwrap(StatusFile.read(from: url))
        XCTAssertEqual(data.last, 0x0A, "editors and `tail -f` both want the newline")
        XCTAssertEqual(StatusFile.load(from: url), built)
    }

    func testASecondWriteInsideTheWindowIsRefused() async throws {
        let url = directory.appendingPathComponent("status.json")
        let writer = StatusFileWriter(fileURL: url)
        let first = StatusFileWriter.build(services: [claude()], costs: [:], agents: .none, now: now)
        let second = StatusFileWriter.build(services: [], costs: [:], agents: .none, now: now.addingTimeInterval(1))

        let wroteFirst = await writer.write(first, now: now)
        XCTAssertTrue(wroteFirst)
        let wroteTooSoon = await writer.write(second, now: now.addingTimeInterval(1))
        XCTAssertFalse(wroteTooSoon)
        XCTAssertEqual(StatusFile.load(from: url)?.services.count, 1, "the refused write left the file alone")

        let wroteSecond = await writer.write(second, now: now.addingTimeInterval(2))
        XCTAssertTrue(wroteSecond)
        XCTAssertEqual(StatusFile.load(from: url)?.services.count, 0)
    }
}
