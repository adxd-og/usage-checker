import XCTest
import SwiftUI
@testable import Omelette

/// The pill's state selection is the whole of its logic: colour and text for a
/// triple of counts, and "draw nothing" when there is nothing to count. Kept out
/// of the view so it can be tested without a hosting window.
final class OMAgentsPillAppearanceTests: XCTestCase {
    private func make(needsYou: Int = 0, working: Int = 0, total: Int) -> OMAgentsPill.Appearance? {
        OMAgentsPill.Appearance.make(needsYou: needsYou, working: working, total: total)
    }

    func testNoSessionsDrawNoPill() {
        // The menu bar is the app's scarcest surface: an empty capsule earns none of it.
        XCTAssertNil(make(total: 0))
    }

    func testQuietSessionsAreGreyAndShowTheTotal() {
        let look = make(total: 3)
        XCTAssertEqual(look?.dot, OMAgentColor.idle)
        XCTAssertEqual(look?.text, "3")
    }

    func testAWorkingSessionTurnsThePillBlueAndCountsOnlyTheWorkingOnes() {
        // Four sessions, two of them busy. The number worth a glance is how many
        // are running, not how many exist.
        let look = make(working: 2, total: 4)
        XCTAssertEqual(look?.dot, OMAgentColor.working)
        XCTAssertEqual(look?.text, "2")
    }

    func testOneWaitingSessionOutranksNineWorkingOnes() {
        let look = make(needsYou: 1, working: 9, total: 10)
        XCTAssertEqual(look?.dot, OMAgentColor.needsYou)
        XCTAssertEqual(look?.textColor, OMAgentColor.needsYou)
        XCTAssertEqual(look?.text, "1 needs you")
    }

    func testTheWaitingCountIsSpelledOutForEveryCount() {
        // Mockup option B: the amber state always says what it wants from you.
        XCTAssertEqual(make(needsYou: 3, working: 0, total: 3)?.text, "3 needs you")
    }

    func testTheAccessibilityLabelNamesTotalAndWaitingSessions() {
        XCTAssertEqual(
            make(needsYou: 2, working: 1, total: 5)?.accessibilityLabel,
            "5 agent sessions, 2 need you"
        )
        XCTAssertEqual(
            make(needsYou: 1, working: 0, total: 1)?.accessibilityLabel,
            "1 agent session, 1 needs you"
        )
        XCTAssertEqual(make(total: 4)?.accessibilityLabel, "4 agent sessions")
    }
}
