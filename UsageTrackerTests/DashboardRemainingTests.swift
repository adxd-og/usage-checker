import SwiftUI
import XCTest
@testable import Omelette

/// The dashboard's Overview. Spec § "Surfaces that switch" — "Dashboard:
/// OverviewView hero and window rows".
final class DashboardRemainingTests: XCTestCase {
    /// The burn card draws a ring for whichever window the provider leads with. A
    /// provider that has reported no window at all has nothing to draw — and "0%
    /// used" and "100% left" are the same nothing, only one of which looks like it.
    func testARingWithNoWindowBehindItIsEmptyInBothModes() {
        let counting = OMRing.geometry(used: nil, mode: .used)
        XCTAssertEqual(counting.trim, 0, accuracy: 0.0001)
        XCTAssertEqual(counting.label, "—")
        XCTAssertEqual(counting.accessibilityValue, "No data")

        let countingDown = OMRing.geometry(used: nil, mode: .remaining)
        XCTAssertEqual(countingDown.trim, 0, accuracy: 0.0001, "a provider with no window is not a full tank")
        XCTAssertEqual(countingDown.label, "—")
        XCTAssertEqual(countingDown.accessibilityValue, "No data")
        XCTAssertNil(countingDown.pace)
    }

    func testAnEmptyRingIsGreyRatherThanAStatusColour() {
        XCTAssertEqual(OMRing.geometry(used: nil, mode: .remaining).color, .secondary)
    }

    func testARingWithAWindowIsUnaffectedByTheOptional() {
        let g = OMRing.geometry(used: 40, mode: .remaining)
        XCTAssertEqual(g.trim, 0.60, accuracy: 0.0001)
        XCTAssertEqual(g.label, "60%")
    }

    /// The Overview's hero is the popover's, reused verbatim: the same window, the
    /// same phrase, the same colour, and now the same switch.
    func testTheOverviewHeroCountsDownWhileItsVerdictStaysOnUsage() {
        let hero = Fixture.bucket(id: "five_hour", label: "Current session", percent: 88, kind: .session)
        XCTAssertEqual(
            OMHero.accessibilityText(for: hero, mode: .remaining),
            "Current session, 12 percent left, Running hot"
        )
        XCTAssertEqual(usageStatusColor(hero.clampedPercent), .orange)
    }

    /// The window rows under the hero draw a bar and no number, so the bar is the
    /// only thing that turns around — and its colour must not.
    func testAWindowRowsBarTurnsAroundButKeepsItsColour() {
        let g = BarSegment.geometry(used: 91, mode: .remaining)
        XCTAssertEqual(g.fillFraction, 0.09, accuracy: 0.0001)
        XCTAssertEqual(g.color, .red)
    }
}
