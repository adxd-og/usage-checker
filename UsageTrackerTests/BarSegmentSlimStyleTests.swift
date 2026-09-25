import XCTest
@testable import Omelette

/// The 3.0 bar of `Popover-Claude.dc.html`'s weekly rows, opt-in so the widget's bars
/// (spec § Decisions, "Widget": untouched in 3.0) stay classic.
final class BarSegmentSlimStyleTests: XCTestCase {
    @MainActor
    func testTheDefaultStyleIsTheClassicBarTheWidgetDraws() {
        XCTAssertEqual(BarSegment(used: 41, mode: .used).style, .classic)
    }

    /// The widget's tick, pinned whole: a 2 pt primary-45 % capsule, 4 pt taller than
    /// the bar, drawn only inside the window.
    func testTheClassicTickIsUnchanged() {
        XCTAssertEqual(BarSegment.tickHeight(barHeight: 6, style: .classic), 10)
        XCTAssertEqual(BarSegment.tickHeight(barHeight: 5, style: .classic), 9)
        XCTAssertEqual(BarSegment.tickWidth, 2)
        XCTAssertEqual(BarSegment.tickCorner, .capsule)
        XCTAssertEqual(BarSegment.classicTickOpacity, 0.45)
        XCTAssertFalse(BarSegment.tickVisible(nil))
        XCTAssertFalse(BarSegment.tickVisible(0.02))
        XCTAssertTrue(BarSegment.tickVisible(0.5))
        XCTAssertFalse(BarSegment.tickVisible(0.98))
    }

    /// A 6 pt bar, a 12 pt tick at `top: -3px`.
    func testTheSlimTickStandsThreePointsProudEachSide() {
        XCTAssertEqual(BarSegment.tickHeight(barHeight: 6, style: .slim), 12)
    }

    func testTheSlimFillTakesTheGaugeToneOnTheUsedValue() {
        XCTAssertEqual(BarSegment.slimFillToken(used: 41), .ok)
        XCTAssertEqual(BarSegment.slimFillToken(used: 75), .warning)
        XCTAssertEqual(BarSegment.slimFillToken(used: 137), .critical)
    }

    func testTheSlimFillFollowsUsedNotTheNumberOnIt() {
        // "5% left" is the same emergency as "95% used".
        XCTAssertEqual(BarSegment.slimFillToken(used: 95), .critical)
        XCTAssertEqual(BarSegment.geometry(used: 95, mode: .remaining).label, "5%")
    }
}
