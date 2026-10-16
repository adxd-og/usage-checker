import XCTest
@testable import Omelette

/// Monotone readings and half-hour bins: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design:
/// - Readings: "made monotone … The window starts at 0";
/// - Bins: "30 minutes from the window start. `Δp` of a bin = the last monotone reading
///   in it minus the last one before it";
/// - Totals: "A reading closes its bin (it belongs to (bin start, bin end])".
final class LimitShareBinsTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let start = Date(timeIntervalSince1970: 1_788_696_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Two hours: four bins.
    private var window: LimitWindow { LimitWindow(start: start, end: at(120)) }

    private func readings(_ points: [(Double, Double)]) -> [LimitReading] {
        LimitShareRules.series(
            Fixture.readings(bucketID: "five_hour", points: points.map { (at: at($0.0), percent: $0.1) }),
            bucketID: "five_hour"
        )
    }

    /// Two dips: 2 → 1 and 3 → 2.
    private var dipping: [LimitReading] { readings([(10, 2), (25, 1), (40, 3), (50, 2), (100, 5)]) }

    func testADipInTheReadingsIsNoiseNotAWindowEmptying() {
        XCTAssertEqual(LimitShareRules.monotone(dipping, in: window).map(\.percent), [2, 2, 3, 3, 5])
    }

    func testABinsDeltaIsItsLastReadingMinusTheLastOneBeforeItFromZero() {
        let bins = LimitShareRules.bins(of: window, readings: LimitShareRules.monotone(dipping, in: window))
        XCTAssertEqual(bins.map(\.delta), [2, 1, 0, 2], "the window starts at 0; a bin with no reading moves by 0")
        XCTAssertEqual(bins.map(\.delta).reduce(0, +), 5, "the deltas add up to the window's percent now")
    }

    func testAReadingIsTheWindowsOnlyAfterItsStartAndUpToItsEnd() {
        let around = readings([(-10, 40), (0, 39), (10, 2), (120, 6), (130, 0)])
        let rising = LimitShareRules.monotone(around, in: window)

        XCTAssertEqual(
            rising,
            [LimitReading(time: at(10), percent: 2), LimitReading(time: at(120), percent: 6)],
            "the previous window's readings, the one on the start itself and the next window's are not this one's"
        )
        XCTAssertEqual(
            LimitShareRules.bins(of: window, readings: rising).map(\.delta), [2, 0, 0, 4],
            "a reading on the end falls in the last bin"
        )
    }

    func testTheBinsAreHalfHoursFromTheWindowsStartTheLastCutShort() {
        let bins = LimitShareRules.bins(of: LimitWindow(start: start, end: at(125)), readings: [])
        XCTAssertEqual(bins.map(\.start), [at(0), at(30), at(60), at(90), at(120)])
        XCTAssertEqual(bins.map(\.delta), [0, 0, 0, 0, 0])
    }

    func testAReadingOnABinsEdgeClosesTheEarlierBin() {
        let edges = readings([(30, 4), (60, 6)])
        let ninety = LimitWindow(start: start, end: at(90))
        XCTAssertEqual(
            LimitShareRules.bins(of: ninety, readings: LimitShareRules.monotone(edges, in: ninety)).map(\.delta),
            [4, 2, 0],
            "a reading belongs to the bin (start, end] it closes"
        )

        // The reading keeps its bin as the window grows past it.
        let onTheEdge = LimitWindow(start: start, end: at(30))
        let aMinuteLater = LimitWindow(start: start, end: at(31))
        XCTAssertEqual(
            LimitShareRules.bins(of: onTheEdge, readings: LimitShareRules.monotone(edges, in: onTheEdge)).map(\.delta),
            [4]
        )
        XCTAssertEqual(
            LimitShareRules.bins(of: aMinuteLater, readings: LimitShareRules.monotone(edges, in: aMinuteLater)).map(\.delta),
            [4, 0]
        )
    }
}
