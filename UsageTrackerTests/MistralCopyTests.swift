import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Windows, plan chip: billing's `plan_name` read as vibe
/// names the chat plans (`FREE` Free, `INDIVIDUAL` Pro, `EDU` Student, `TEAM` Team); an unknown
/// name is shown capitalised, its control characters dropped; no name is no chip.
final class MistralCopyTests: XCTestCase {
    func testTheChatPlansReadAsVibeNamesThem() {
        XCTAssertEqual(MistralCopy.planName("FREE"), "Free")
        XCTAssertEqual(MistralCopy.planName("INDIVIDUAL"), "Pro")
        XCTAssertEqual(MistralCopy.planName("EDU"), "Student")
        XCTAssertEqual(MistralCopy.planName("TEAM"), "Team")
        XCTAssertEqual(MistralCopy.planName("individual"), "Pro")
    }

    func testAnUnknownPlanIsShownCapitalised() {
        XCTAssertEqual(MistralCopy.planName("ENTERPRISE"), "Enterprise")
        XCTAssertEqual(MistralCopy.planName("SCALE_UP"), "Scale Up")
    }

    func testNoPlanNameIsNoChip() {
        XCTAssertNil(MistralCopy.planName(nil))
        XCTAssertNil(MistralCopy.planName(""))
        XCTAssertNil(MistralCopy.planName("  "))
    }

    /// Billing's `plan_name` reaches the chip and `brioche status`: ESC, BEL and C1 controls go.
    func testAPlanNameLosesItsControlCharacters() {
        XCTAssertEqual(MistralCopy.planName("ENTER\u{1B}PRISE\u{07}"), "Enterprise")
        XCTAssertEqual(MistralCopy.planName("SCALE\u{9B}_UP"), "Scale Up")
        XCTAssertEqual(MistralCopy.planName("TE\u{85}AM"), "Team")
    }

    func testAPlanNameOfOnlyControlsIsNoChip() {
        XCTAssertNil(MistralCopy.planName("\u{1B}\u{07}\u{9B}"))
        XCTAssertNil(MistralCopy.planName(" \u{1B} \u{00} "))
    }
}
