import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Windows, plan chip: billing's `plan_name` read as vibe
/// names the chat plans (`FREE` Free, `INDIVIDUAL` Pro, `EDU` Student, `TEAM` Team); an unknown
/// name is shown capitalised; no name is no chip.
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
}
