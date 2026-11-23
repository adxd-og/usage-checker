import XCTest
@testable import Omelette

/// 4.4.0 release review, R1: the All providers widget's single row (five providers listed)
/// is the window nearest the limit, the session keeping a tie, and a promotional pool takes
/// that row only when the provider has nothing else, whatever its percent; with two rows
/// nothing changes. The ring (`WidgetService.headlineBucket`) keeps promo pools out the same
/// way. The cases here are the ones `WidgetAllProvidersRulesTests` does not reach.
final class ReleaseReview440VerificationTests: XCTestCase {
    private func service(_ buckets: [WidgetBucket], retained: Bool = false) -> WidgetService {
        WidgetService(id: "claude", name: "Claude", icon: "circle", plan: nil, buckets: buckets, isRetained: retained)
    }

    private func bucket(_ id: String, _ percent: Double, _ kind: String, label: String = "Window") -> WidgetBucket {
        WidgetBucket(id: id, label: label, percent: percent, kind: kind)
    }

    private func oneRow(_ s: WidgetService) -> [String] {
        WidgetEntryRules.windowRows(of: s, limit: 1).map(\.id)
    }

    func testSeveralPromotionalPoolsNeverTakeTheRowFromAWindowThatCounts() {
        let s = service([
            bucket("five_hour", 5, "session"),
            bucket("seven_day_a_promotional", 100, "modelSpecific"),
            bucket("seven_day_b_promotional", 90, "modelSpecific"),
        ])
        XCTAssertEqual(oneRow(s), ["five_hour"])
    }

    func testWhenPromotionalPoolsAreAllThereIsTheFullestOneTakesTheRow() {
        let s = service([
            bucket("seven_day_a_promotional", 40, "modelSpecific"),
            bucket("seven_day_b_promotional", 90, "modelSpecific"),
        ])
        XCTAssertEqual(oneRow(s), ["seven_day_b_promotional"])
    }

    func testAPromotionalPoolTiedWithTheSessionLeavesTheRowToTheSession() {
        let s = service([
            bucket("seven_day_omelette_promotional", 100, "modelSpecific"),
            bucket("five_hour", 100, "session"),
        ])
        XCTAssertEqual(oneRow(s), ["five_hour"])
    }

    func testAModelScopedWindowBeatsAFullerPromotionalPoolWithoutASession() {
        let s = service([
            bucket("seven_day_omelette_promotional", 100, "modelSpecific"),
            bucket("seven_day_fable", 20, "modelSpecific", label: "Fable only"),
        ])
        XCTAssertEqual(oneRow(s), ["seven_day_fable"])
    }

    func testAPromotionalPoolKnownOnlyByItsLabelIsKeptOffTheRowToo() {
        let s = service([
            bucket("five_hour", 10, "session"),
            bucket("bonus_pool", 99, "other", label: "Weekend Promotional"),
        ])
        XCTAssertEqual(oneRow(s), ["five_hour"])
        let alone = service([bucket("bonus_pool", 99, "other", label: "Weekend Promotional")])
        XCTAssertEqual(oneRow(alone), ["bonus_pool"], "all there is")
    }

    func testAProviderWithNoWindowsHasNoRowAtEitherLimit() {
        XCTAssertTrue(WidgetEntryRules.windowRows(of: service([]), limit: 1).isEmpty)
        XCTAssertTrue(WidgetEntryRules.windowRows(of: service([]), limit: 2).isEmpty)
    }

    func testWindowsAllAtZeroStillGiveOneRowAndTheSessionKeepsIt() {
        let s = service([
            bucket("seven_day_omelette_promotional", 0, "modelSpecific"),
            bucket("seven_day", 0, "weekly"),
            bucket("five_hour", 0, "session"),
        ])
        XCTAssertEqual(oneRow(s), ["five_hour"])
        let noSession = service([
            bucket("seven_day_omelette_promotional", 0, "modelSpecific"),
            bucket("seven_day", 0, "weekly"),
        ])
        XCTAssertEqual(oneRow(noSession), ["seven_day"], "a counted window at 0 % before a promo pool at 0 %")
    }

    func testARetainedProviderGetsTheSameRowAsALiveOne() {
        let buckets = [
            bucket("five_hour", 10, "session"),
            bucket("seven_day_omelette_promotional", 100, "modelSpecific"),
            bucket("seven_day", 30, "weekly"),
        ]
        XCTAssertEqual(oneRow(service(buckets, retained: true)), oneRow(service(buckets)))
        XCTAssertEqual(oneRow(service(buckets, retained: true)), ["seven_day"])
    }

    func testTwoRowsAreUnchangedWhenAPromotionalPoolIsTheOnlyOtherWindow() {
        let s = service([
            bucket("seven_day_omelette_promotional", 100, "modelSpecific"),
            bucket("five_hour", 10, "session"),
        ])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: s, limit: 2).map(\.id), ["five_hour", "seven_day_omelette_promotional"])
    }

    /// The ring and the single row, for a provider with a session and a promo pool at any
    /// percent: both show the session when nothing else beats it.
    func testTheRingAndTheSingleRowAgreeWhenAPromotionalPoolIsTheFullest() {
        let s = service([
            bucket("five_hour", 10, "session"),
            bucket("seven_day_omelette_promotional", 100, "modelSpecific"),
        ])
        XCTAssertEqual(s.headlineBucket?.id, "five_hour")
        XCTAssertEqual(oneRow(s), [s.headlineBucket?.id ?? ""])
    }

    /// R1: a promotional pool takes the single row only when the provider has nothing else.
    /// A promotional window of kind "session" (Claude's dynamic keys are given that kind by
    /// their name alone) is a promotional pool; the ring skips it and so must the row.
    func testAPromotionalWindowOfKindSessionDoesNotTakeTheRowFromAWeekThatCounts() {
        let s = service([
            bucket("five_hour_promotional", 100, "session"),
            bucket("seven_day", 30, "weekly"),
        ])
        XCTAssertEqual(s.headlineBucket?.id, "seven_day", "the ring keeps the promo window out")
        XCTAssertEqual(oneRow(s), ["seven_day"])
    }

    // MARK: - The session pick past a promotional session (second round)

    private let promoSession = WidgetBucket(id: "five_hour_promotional", label: "Bonus", percent: 100, kind: "session")
    private let countedSession = WidgetBucket(id: "five_hour", label: "Session", percent: 10, kind: "session")
    private let countedWeek = WidgetBucket(id: "seven_day", label: "All models", percent: 30, kind: "weekly")
    private let promoPool = WidgetBucket(id: "seven_day_x_promotional", label: "Bonus pool", percent: 95, kind: "modelSpecific")
    private let lowPromoPool = WidgetBucket(id: "seven_day_y_promotional", label: "Bonus pool 2", percent: 40, kind: "modelSpecific")

    /// A counted session is the session whichever side of a promotional session it sits on.
    func testACountedSessionTakesTheRowOnEitherSideOfAPromotionalSession() {
        XCTAssertEqual(oneRow(service([promoSession, countedSession])), ["five_hour"])
        XCTAssertEqual(oneRow(service([countedSession, promoSession])), ["five_hour"])
        XCTAssertEqual(oneRow(service([promoSession, countedSession, promoPool])), ["five_hour"])
        XCTAssertEqual(oneRow(service([promoSession, countedSession, countedWeek])), ["seven_day"])
    }

    /// Two counted sessions: the first leads, as it does in the ring (`headlineBucket`).
    func testTheFirstOfTwoCountedSessionsIsTheOneThatTakesTheRow() {
        let second = WidgetBucket(id: "session_b", label: "Session B", percent: 20, kind: "session")
        let s = service([promoSession, countedSession, second])
        XCTAssertEqual(s.headlineBucket?.id, "five_hour")
        XCTAssertEqual(oneRow(s), ["five_hour"])
    }

    /// No counted session: the fullest counted window, never a promotional session or pool.
    func testWithOnlyAPromotionalSessionTheFullestCountedWindowTakesTheRow() {
        XCTAssertEqual(oneRow(service([promoSession, countedWeek])), ["seven_day"])
        XCTAssertEqual(oneRow(service([promoSession, countedWeek, promoPool])), ["seven_day"])
    }

    /// Nothing counted at all: the promotional session leads, then the fullest promotional pool.
    func testWithNothingButPromotionalWindowsTheSessionLeadsThenTheFullestPool() {
        XCTAssertEqual(oneRow(service([promoSession])), ["five_hour_promotional"])
        XCTAssertEqual(oneRow(service([lowPromoPool, promoSession, promoPool])), ["five_hour_promotional"])
        XCTAssertEqual(oneRow(service([lowPromoPool, promoPool])), ["seven_day_x_promotional"])
    }

    /// A counted session at 0 % against a promotional session and pool at 100 %.
    func testPromotionalWindowsAtAnyPercentNeverTakeTheRowFromACountedSessionAtZero() {
        let zero = WidgetBucket(id: "five_hour", label: "Session", percent: 0, kind: "session")
        XCTAssertEqual(oneRow(service([promoSession, promoPool, zero])), ["five_hour"])
    }

    /// Two rows are as they were: the first session-kind bucket, promotional or not, then the fullest others.
    func testTwoRowsStillOpenWithTheFirstSessionKindBucketAndTheFullestOthers() {
        XCTAssertEqual(
            WidgetEntryRules.windowRows(of: service([promoSession, countedSession, countedWeek]), limit: 2).map(\.id),
            ["five_hour_promotional", "seven_day"]
        )
        XCTAssertEqual(
            WidgetEntryRules.windowRows(of: service([promoSession, promoPool]), limit: 2).map(\.id),
            ["five_hour_promotional", "seven_day_x_promotional"]
        )
    }
}
