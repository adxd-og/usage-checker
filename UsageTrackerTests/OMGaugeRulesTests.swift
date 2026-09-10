import SwiftUI
import XCTest
@testable import Omelette

/// What a ring and a bar actually draw. The spec's own test line: "Colour tests
/// assert the colour follows `used` while the number follows the mode."
final class OMGaugeRulesTests: XCTestCase {
    // MARK: - OMRing

    func testTheRingFillsToTheUsedValueByDefault() {
        let g = OMRing.geometry(used: 37, mode: .used)
        XCTAssertEqual(g.trim, 0.37, accuracy: 0.0001)
        XCTAssertEqual(g.label, "37%")
        XCTAssertEqual(g.accessibilityValue, "37 percent used")
    }

    func testTheRingFillsToWhatIsLeftInRemainingMode() {
        // 63% of the ring at 63% left — the spec's own sentence.
        let g = OMRing.geometry(used: 37, mode: .remaining)
        XCTAssertEqual(g.trim, 0.63, accuracy: 0.0001)
        XCTAssertEqual(g.label, "63%")
        XCTAssertEqual(g.accessibilityValue, "63 percent left")
    }

    func testTheRingsColourFollowsUsageNotTheNumberOnIt() {
        // 95% used is red. Showing "5% left" must not turn it green.
        XCTAssertEqual(OMRing.geometry(used: 95, mode: .used).color, .red)
        XCTAssertEqual(OMRing.geometry(used: 95, mode: .remaining).color, .red)
        XCTAssertEqual(OMRing.geometry(used: 75, mode: .remaining).color, .orange)
        XCTAssertEqual(OMRing.geometry(used: 12, mode: .remaining).color, .green)
    }

    func testAnEmptyWindowStillDrawsAHairOfArcSoTheRingIsNeverAPerfectVoid() {
        XCTAssertEqual(OMRing.geometry(used: 0, mode: .used).trim, 0.004, accuracy: 0.0001)
        XCTAssertEqual(OMRing.geometry(used: 100, mode: .remaining).trim, 0.004, accuracy: 0.0001)
    }

    func testAnExplicitColourStillWins() {
        XCTAssertEqual(OMRing.geometry(used: 95, mode: .remaining, color: .blue).color, .blue)
    }

    func testTheRingsPaceMarkerMirrorsWithTheFill() {
        XCTAssertEqual(try XCTUnwrap(OMRing.geometry(used: 37, mode: .used, pace: 0.25).pace), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(OMRing.geometry(used: 37, mode: .remaining, pace: 0.25).pace), 0.75, accuracy: 0.0001)
        XCTAssertNil(OMRing.geometry(used: 37, mode: .remaining, pace: nil).pace)
    }

    // MARK: - BarSegment

    func testTheBarFillsToTheUsedValueByDefault() {
        let g = BarSegment.geometry(used: 18, mode: .used)
        XCTAssertEqual(g.fillFraction, 0.18, accuracy: 0.0001)
        XCTAssertEqual(g.label, "18%")
        XCTAssertEqual(g.accessibilityValue, "18 percent used")
    }

    func testTheBarFillsToWhatIsLeftInRemainingMode() {
        let g = BarSegment.geometry(used: 18, mode: .remaining)
        XCTAssertEqual(g.fillFraction, 0.82, accuracy: 0.0001)
        XCTAssertEqual(g.label, "82%")
        XCTAssertEqual(g.accessibilityValue, "82 percent left")
    }

    func testTheBarsColourAndItsWarningLabelBothFollowUsage() {
        // At 8% left the bar is red and its label is coloured, even though the
        // number on it is small.
        let hot = BarSegment.geometry(used: 92, mode: .remaining)
        XCTAssertEqual(hot.color, .red)
        XCTAssertTrue(hot.labelIsColored)
        XCTAssertEqual(hot.label, "8%")

        // At 92% left the bar is green and the label is quiet, even though the
        // number on it is large.
        let calm = BarSegment.geometry(used: 8, mode: .remaining)
        XCTAssertEqual(calm.color, .green)
        XCTAssertFalse(calm.labelIsColored)
        XCTAssertEqual(calm.label, "92%")
    }

    func testTheBarNeverOverflowsOnAWindowPastItsLimit() {
        XCTAssertEqual(BarSegment.geometry(used: 137, mode: .used).fillFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(BarSegment.geometry(used: 137, mode: .remaining).fillFraction, 0, accuracy: 0.0001)
    }

    func testTheBarsPaceTickMirrorsWithTheFill() {
        XCTAssertEqual(try XCTUnwrap(BarSegment.geometry(used: 18, mode: .remaining, pace: 0.4).pace), 0.6, accuracy: 0.0001)
    }
}
