import XCTest
@testable import Omelette

/// Where the "API-equivalent" sentence lands, as a pure rule: the daily summary body.
/// History's header says it in its own sentence (`HistoryCopySubtitleTests`); the
/// popover and the Overview compose `CostCopy.apiEquivalentCaption` directly.
final class ApiEquivalentCaptionTests: XCTestCase {
    // MARK: - UsageNotifier.dailySummaryBody

    func testTheDailySummarySaysWhatKindOfDollarsThoseAre() {
        XCTAssertEqual(
            UsageNotifier.dailySummaryBody(cost: 4.2, turns: 23, isPayAsYouGo: false),
            "Yesterday: $4.20 across 23 turns. (API-equivalent)"
        )
    }

    func testPayAsYouGoGetsTheBillWithNoQualifier() {
        XCTAssertEqual(
            UsageNotifier.dailySummaryBody(cost: 4.2, turns: 23, isPayAsYouGo: true),
            "Yesterday: $4.20 across 23 turns."
        )
    }

    func testAQuietDayIsStillAQuietDay() {
        XCTAssertEqual(
            UsageNotifier.dailySummaryBody(cost: 0, turns: 0, isPayAsYouGo: false),
            "No Claude Code activity yesterday."
        )
    }
}
