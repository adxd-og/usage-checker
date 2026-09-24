import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Time zone: "Codex's `dayStart` and `costs()` use the same calendar." `costs()` and
/// `breakdown()` took "today" from a fresh `Calendar.current` while the daily rows came
/// off the aggregator's own, so "today" and today's row sat on two different midnights
/// whenever the two calendars disagreed (report B #4).
final class CodexCalendarTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let threadID = "01a07e24-6f3a-7b18-9c4d-7e2a5f8b1d63"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCalendarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            )
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    /// A zone twelve hours from this Mac's, so its day and `Calendar.current`'s never
    /// start at the same hour: an aggregator that reached for the machine's calendar
    /// instead of its own puts the turns below in the wrong day, on any machine.
    private var farCalendar: Calendar {
        let machine = TimeZone.current.secondsFromGMT()
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: machine >= 0 ? machine - 12 * 3600 : machine + 12 * 3600)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// Two hours into the latest day of `cal` that has already begun.
    private func dayNow(in cal: Calendar) -> Date {
        let real = Date()
        let candidate = cal.startOfDay(for: real).addingTimeInterval(2 * 3600)
        return candidate > real ? candidate.addingTimeInterval(-86_400) : candidate
    }

    /// One response at `turnAt`: 1_000 in (400 cached), 100 out — $0.0018.
    private func writeResponse(at turnAt: Date) throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: turnAt.addingTimeInterval(-60)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: turnAt.addingTimeInterval(-30)),
            CodexRollout.record(at: turnAt, threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-06T02-09-23-\(threadID).jsonl")
    }

    func testAnHourBeforeTheCalendarsMidnightIsYesterday() async throws {
        let cal = farCalendar
        let now = dayNow(in: cal)
        let turnAt = now.addingTimeInterval(-3 * 3600)
        try writeResponse(at: turnAt)
        let aggregator = tree.aggregator(calendar: cal)

        let costs = await aggregator.costs(now: now)
        XCTAssertEqual(costs.today, 0, accuracy: 1e-12, "yesterday in this calendar, today in the machine's")
        XCTAssertEqual(costs.week, 0.0018, accuracy: 1e-12)

        let breakdown = await aggregator.breakdown(now: now)
        XCTAssertEqual(breakdown.todayTurns, 0)
        XCTAssertEqual(breakdown.todayCost, 0, accuracy: 1e-12)
        XCTAssertEqual(breakdown.weekCost, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(
            breakdown.daily.map(\.day), [cal.startOfDay(for: turnAt)],
            "the row and 'today' come off one calendar"
        )
    }

    func testAnHourAfterTheCalendarsMidnightIsToday() async throws {
        let cal = farCalendar
        let now = dayNow(in: cal)
        try writeResponse(at: now.addingTimeInterval(-3600))
        let aggregator = tree.aggregator(calendar: cal)

        let costs = await aggregator.costs(now: now)
        XCTAssertEqual(costs.today, 0.0018, accuracy: 1e-12)
        let breakdown = await aggregator.breakdown(now: now)
        XCTAssertEqual(breakdown.todayTurns, 1)
        XCTAssertEqual(breakdown.todayCost, 0.0018, accuracy: 1e-12)
    }
}
