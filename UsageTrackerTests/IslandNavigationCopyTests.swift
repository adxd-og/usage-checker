import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 and § 3.8: the words of the island's navigation — "‹ All",
/// the logos beside the camera (their tooltips name the shortcut, VoiceOver hears a waiting
/// agent) and a tile's hint.
final class IslandNavigationCopyTests: XCTestCase {
    func testBackSaysAllAndVoiceOverHearsWhereItGoes() {
        XCTAssertEqual(IslandNavigationCopy.backTitle, "All")
        XCTAssertEqual(IslandNavigationCopy.backAccessibilityLabel, "Back to all providers")
        XCTAssertEqual(IslandNavigationCopy.backHelp, "All providers (⌘0)")
    }

    func testALogosTooltipNamesItsShortcut() {
        XCTAssertEqual(IslandNavigationCopy.logoHelp(name: "Claude", position: 1), "Claude (⌘1)")
        XCTAssertEqual(IslandNavigationCopy.logoHelp(name: "Grok", position: 5), "Grok (⌘5)")
        XCTAssertEqual(IslandNavigationCopy.logoHelp(name: "Other", position: 10), "Other", "no key past ⌘9")
        XCTAssertEqual(IslandNavigationCopy.logoHelp(name: "Other", position: 0), "Other")
    }

    func testALogoSaysWhenAnAgentWaits() {
        XCTAssertEqual(IslandNavigationCopy.logoAccessibilityLabel(name: "Claude", waiting: false), "Claude")
        XCTAssertEqual(IslandNavigationCopy.logoAccessibilityLabel(name: "Claude", waiting: true), "Claude, an agent needs you")
    }

    func testATilesHintSaysWhatAClickDoes() {
        XCTAssertEqual(IslandNavigationCopy.tileHint, "Opens details")
        XCTAssertEqual(IslandNavigationCopy.waitingPhrase, "an agent needs you")
    }
}
