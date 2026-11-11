import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Attribution and What the app has already
/// counted: the first point's whole total goes to its own moment, each later rise to the point
/// that first shows it, a repeat to nothing. The highest total attributed is a high-water mark:
/// a lower total attributes nothing and does not lower it, and only what rises above it counts.
/// Arithmetic saturates. Old steps fold to one per day after a month and go after a year (R8).
final class VibeLedgerTests: XCTestCase {
    private typealias Point = VibeSessionStore.Point
    private typealias Step = VibeLedger.Step

    /// 2026-11-06 18:00 UTC, a Friday.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func point(_ ms: Int64, _ input: Int, _ cached: Int, _ output: Int) -> Point {
        Point(at: Date(timeIntervalSince1970: Double(ms) / 1000), input: input, cached: cached, output: output)
    }

    private func step(_ ms: Int64, _ input: Int, _ cached: Int, _ output: Int, turns: Int = 1) -> Step {
        Step(at: Date(timeIntervalSince1970: Double(ms) / 1000), input: input, cached: cached, output: output, turns: turns)
    }

    /// The whole-journal fixture's points as `VibeSessionStore` reads them.
    private var whole: [Point] {
        [
            point(1_793_977_712_751, 7_180, 2_816, 2_532),
            point(1_793_977_712_759, 7_180, 2_816, 2_532),
            point(1_793_977_714_212, 18_093, 9_728, 2_579),
            point(1_793_977_720_616, 29_115, 12_800, 2_697),
            point(1_793_977_728_714, 40_314, 23_552, 2_747),
            point(1_793_977_733_201, 51_611, 34_560, 2_822),
            point(1_793_977_736_011, 63_031, 45_568, 3_101),
            point(1_793_977_736_011, 63_031, 45_568, 3_101),
        ]
    }

    /// The pruned fixture's final total: the mark after both of its steps.
    private let prunedMark = VibeLedger.Counters(input: 791_586, cached: 667_648, output: 6_411)

    private func ledger(_ steps: [Step], touched: Date) -> VibeLedger {
        var session = VibeLedger.Session()
        session.steps = steps
        session.mark = VibeSessionStore.Mark(newest: touched, bytes: 1, files: 1)
        return VibeLedger(sessions: ["s": session])
    }

    func testTheFirstPointGivesItsWholeTotalToItsOwnMoment() {
        let result = VibeLedger.attribute([point(1_793_978_821_829, 745_677, 623_104, 6_170)], after: VibeLedger.Counters())
        XCTAssertEqual(result.steps, [step(1_793_978_821_829, 745_677, 623_104, 6_170)])
        XCTAssertEqual(result.counted, VibeLedger.Counters(input: 745_677, cached: 623_104, output: 6_170))
    }

    func testEachRiseGoesToThePointThatFirstShowsIt() {
        let result = VibeLedger.attribute(whole, after: VibeLedger.Counters())
        XCTAssertEqual(result.steps, [
            step(1_793_977_712_751, 7_180, 2_816, 2_532),
            step(1_793_977_714_212, 10_913, 6_912, 47),
            step(1_793_977_720_616, 11_022, 3_072, 118),
            step(1_793_977_728_714, 11_199, 10_752, 50),
            step(1_793_977_733_201, 11_297, 11_008, 75),
            step(1_793_977_736_011, 11_420, 11_008, 279),
        ])
        XCTAssertEqual(result.steps.map { $0.input + $0.output }, [9_712, 10_960, 11_140, 11_249, 11_372, 11_699])
        XCTAssertEqual(result.counted.total, 66_132)
    }

    func testARepeatedTotalAddsNothing() {
        let result = VibeLedger.attribute([
            point(1_793_977_627_409, 6_930, 3_072, 67),
            point(1_793_977_627_414, 6_930, 3_072, 67),
            point(1_793_977_638_323, 6_930, 3_072, 67),
        ], after: VibeLedger.Counters())
        XCTAssertEqual(result.steps, [step(1_793_977_627_409, 6_930, 3_072, 67)])
    }

    func testTokensAlreadyCountedAreNeverCountedAgainWhenTheJournalWasPruned() {
        // Counted up to 1 623 625 before midnight; after it, vibe has pruned the session to a
        // generation at 1 821 415.
        let counted = VibeLedger.Counters(input: 1_620_647, cached: 1_449_024, output: 2_978)
        let result = VibeLedger.attribute([point(1_793_978_272_490, 1_802_736, 1_622_336, 18_679)], after: counted)
        XCTAssertEqual(result.steps, [step(1_793_978_272_490, 182_089, 173_312, 15_701)], "only the 197 790 not seen before")
    }

    func testALowerTotalCountsNothingAndLeavesTheMarkWhereItWas() {
        let lower = VibeLedger.attribute([point(1_793_978_900_000, 6_930, 3_072, 67)], after: prunedMark)
        XCTAssertEqual(lower.steps, [])
        XCTAssertEqual(lower.counted, prunedMark, "a read that raced vibe's write does not lower the mark")
        let again = VibeLedger.attribute(
            [point(1_793_978_900_000, 6_930, 3_072, 67), point(1_793_978_960_000, 791_586, 667_648, 6_411)],
            after: lower.counted
        )
        XCTAssertEqual(again.steps, [], "the old total seen again counts nothing twice")
        XCTAssertEqual(again.counted, prunedMark)
    }

    func testAfterALowerTotalOnlyWhatRisesAboveTheMarkCounts() {
        let result = VibeLedger.attribute(
            [point(1_793_978_900_000, 6_930, 3_072, 67), point(1_793_978_960_000, 793_586, 668_648, 6_511)],
            after: prunedMark
        )
        XCTAssertEqual(result.steps, [step(1_793_978_960_000, 2_000, 1_000, 100)], "800 097 − 797 997")
        XCTAssertEqual(result.counted.total, 800_097)
    }

    func testAComponentThatShrinksCountsZeroNotLess() {
        let result = VibeLedger.attribute(
            [point(1_000_000, 10_000, 8_000, 100), point(2_000_000, 12_000, 7_000, 150)], after: VibeLedger.Counters()
        )
        XCTAssertEqual(result.steps.last, step(2_000_000, 2_000, 0, 50))
    }

    func testExtremeCountersSaturateInsteadOfTrapping() {
        let near = VibeLedger.attribute(
            [point(1_000, Int.max - 1, 0, 1), point(2_000, Int.max, 0, 5)], after: VibeLedger.Counters()
        )
        XCTAssertEqual(near.steps, [step(1_000, Int.max - 1, 0, 1)], "both totals saturate at Int.max: the second rises above nothing")
        XCTAssertEqual(near.counted.total, Int.max)
        let damaged = VibeLedger.attribute(
            [point(3_000, 100, 0, 0)], after: VibeLedger.Counters(input: -50, cached: -7, output: -1)
        )
        XCTAssertEqual(damaged.steps, [step(3_000, 100, 0, 0)], "a negative count from a damaged ledger reads as zero")
        XCTAssertEqual(VibeLedger.rise(5, over: Int.min), Int.max)
        XCTAssertEqual(VibeLedger.rise(Int.min, over: 5), 0)
        let half = Int.max / 2 + 1
        let folded = ledger(
            [step(1_788_256_800_000, half, half, half), step(1_788_264_000_000, half, half, half)], touched: now
        ).tidied(now: now, calendar: utc)
        XCTAssertEqual(folded.sessions["s"]?.steps, [step(1_788_264_000_000, Int.max, Int.max, Int.max, turns: 2)])
    }

    func testStepsOlderThanAMonthFoldIntoOnePerDayAndKeepTheirTurns() {
        // 1 September 2026 10:00 and 12:00, 2 September 09:00 (UTC), then 6 November.
        let tidied = ledger([
            step(1_788_256_800_000, 100, 10, 5),
            step(1_788_264_000_000, 200, 20, 7),
            step(1_788_339_600_000, 300, 30, 9),
            step(1_793_977_200_000, 400, 40, 11),
        ], touched: now).tidied(now: now, calendar: utc)
        XCTAssertEqual(tidied.sessions["s"]?.steps, [
            step(1_788_264_000_000, 300, 30, 12, turns: 2),
            step(1_788_339_600_000, 300, 30, 9),
            step(1_793_977_200_000, 400, 40, 11),
        ])
    }

    func testStepsOlderThanAYearAreDropped() {
        let tidied = ledger(
            [step(1_762_279_200_000, 100, 10, 5), step(1_793_977_200_000, 400, 40, 11)], touched: now
        ).tidied(now: now, calendar: utc)
        XCTAssertEqual(tidied.sessions["s"]?.steps, [step(1_793_977_200_000, 400, 40, 11)])
    }

    func testASessionWithNothingLeftIsForgottenOnlyOnceUntouchedForAYear() {
        let stale = ledger([], touched: now.addingTimeInterval(-400 * 86_400)).tidied(now: now, calendar: utc)
        XCTAssertNil(stale.sessions["s"])
        let quiet = ledger([], touched: now.addingTimeInterval(-86_400)).tidied(now: now, calendar: utc)
        XCTAssertNotNil(quiet.sessions["s"], "an opened-and-closed session stays marked, so it is not read at every poll")
    }
}
