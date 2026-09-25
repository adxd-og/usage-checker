import XCTest
@testable import Omelette

/// The one-time hooks offer in the 3.0 popover: a group card like the agents below it,
/// and — spec § Principles 2, "the only filled control is the primary action (Allow)" —
/// an Enable that is a glass capsule, not a second filled button.
final class OMHooksPromptRowTests: XCTestCase {
    func testThePromptIsAGroupCardWithTheWorkingBlueIcon() {
        XCTAssertEqual(OMHooksPromptRow.surface, .group)
        XCTAssertEqual(OMHooksPromptRow.iconToken, .working)
        XCTAssertEqual(OMHooksPromptRow.verticalPadding, 12)
        XCTAssertEqual(OMHooksPromptRow.horizontalPadding, 14)
    }

    func testEnableIsASmallGlassCapsule() {
        XCTAssertEqual(OMHooksPromptRow.enableButtonSize, .small)
    }

    func testItsWordsAreUnchanged() {
        XCTAssertEqual(OMHooksPromptRow.title, "See what your agents are doing")
        XCTAssertTrue(OMHooksPromptRow.caption.hasPrefix("Adds hooks to ~/.claude/settings.json"))
    }
}
