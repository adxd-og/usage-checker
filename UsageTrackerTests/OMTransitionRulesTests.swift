import XCTest
@testable import Omelette

/// Owner's check of the 3.0 screens (2026-09-25): a tab switch on the dashboard, in
/// Settings and in the popover cut from one page to the next. It now cross-fades over
/// 0.18 s, the incoming page sliding 8 pt in from the side it comes from; a plain fade when
/// that side is unknown; nothing under Reduce Motion.
final class OMTransitionRulesTests: XCTestCase {
    private let order = ["overview", "agents", "history", "insights"]

    func testATabSwitchFadesOverEighteenHundredthsWithAnEightPointSlide() {
        XCTAssertEqual(OMTransitionRules.tab(reduceMotion: false), OMTabTransition(duration: 0.18, offset: 8))
    }

    func testReduceMotionSwitchesTabsWithoutMotion() {
        XCTAssertNil(OMTransitionRules.tab(reduceMotion: true))
    }

    func testMovingDownTheOrderTravelsForward() {
        XCTAssertEqual(OMTransitionRules.direction(from: "overview", to: "history", in: order), 1)
    }

    func testMovingUpTheOrderTravelsBack() {
        XCTAssertEqual(OMTransitionRules.direction(from: "insights", to: "agents", in: order), -1)
    }

    func testNoPreviousTabOrOneOutsideTheOrderHasNoDirection() {
        XCTAssertEqual(OMTransitionRules.direction(from: nil, to: "agents", in: order), 0)
        XCTAssertEqual(OMTransitionRules.direction(from: "activity", to: "agents", in: order), 0)
        XCTAssertEqual(OMTransitionRules.direction(from: "agents", to: "activity", in: order), 0)
    }

    func testTheSameTabHasNoDirection() {
        XCTAssertEqual(OMTransitionRules.direction(from: "agents", to: "agents", in: order), 0)
    }

    /// Forward, the page comes in from below (or the right) and settles; back, from above
    /// (or the left).
    func testTheIncomingPageStartsOnTheSideItComesFrom() {
        let motion = OMTransitionRules.tab(reduceMotion: false)
        XCTAssertEqual(OMTransitionRules.insertionOffset(from: "overview", to: "insights", in: order, transition: motion), 8)
        XCTAssertEqual(OMTransitionRules.insertionOffset(from: "insights", to: "overview", in: order, transition: motion), -8)
    }

    func testWithNoKnownSideTheSwitchIsAPlainFade() {
        let motion = OMTransitionRules.tab(reduceMotion: false)
        XCTAssertEqual(OMTransitionRules.insertionOffset(from: nil, to: "agents", in: order, transition: motion), 0)
    }

    func testUnderReduceMotionNothingSlides() {
        XCTAssertEqual(OMTransitionRules.insertionOffset(from: "overview", to: "insights", in: order, transition: nil), 0)
    }
}
