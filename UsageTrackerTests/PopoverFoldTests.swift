import XCTest
import CodexBarCore
@testable import Omelette

/// Spec 2026-10-16-antigravity-argon § Design "Popover fold": only `.modelSpecific`
/// windows under 0.05% fold behind "N unused windows". A `.weekly` window always keeps
/// its row; Claude's `seven_day` exemption is a case of the rule.
final class PopoverFoldTests: XCTestCase {
    func testAWeeklyWindowAtZeroKeepsItsRow() {
        XCTAssertFalse(PopoverView.foldsWhenUnused(Fixture.bucket(
            id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", percent: 0, kind: .weekly)))
        XCTAssertFalse(PopoverView.foldsWhenUnused(Fixture.bucket(
            id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", percent: 0.01021, kind: .weekly)))
    }

    func testClaudesAllModelsWeeklyNeverFolds() {
        XCTAssertFalse(PopoverView.foldsWhenUnused(Fixture.bucket(id: "seven_day", label: "All models", percent: 0, kind: .weekly)))
    }

    func testAnUntouchedModelSpecificWindowFolds() {
        XCTAssertTrue(PopoverView.foldsWhenUnused(Fixture.bucket(
            id: "seven_day_sonnet", label: "Sonnet only", percent: 0, kind: .modelSpecific)))
        XCTAssertTrue(PopoverView.foldsWhenUnused(Fixture.bucket(
            id: "seven_day_opus", label: "Opus only", percent: 0.049, kind: .modelSpecific)))
    }

    func testAModelSpecificWindowInUseKeepsItsRow() {
        XCTAssertFalse(PopoverView.foldsWhenUnused(Fixture.bucket(
            id: "seven_day_opus", label: "Opus only", percent: 0.05, kind: .modelSpecific)))
        XCTAssertFalse(PopoverView.foldsWhenUnused(Fixture.bucket(
            id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini Argon",
            percent: 44.32, kind: .modelSpecific)))
    }

    /// Spec § Design "What the user sees": on the Pro payload the weekly rows are Gemini
    /// weekly 0%, Claude/GPT weekly 0% and Gemini Argon 44%, with no "unused windows" row.
    func testTheAntigravityProTabFoldsNothing() {
        let buckets = AntigravityProvider.buckets(from: AntigravityFixture.proSummary)
        XCTAssertEqual(buckets.filter(PopoverView.foldsWhenUnused).map(\.id), [])
    }
}
