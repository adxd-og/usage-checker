import XCTest
import CodexBarCore
@testable import Omelette

/// Spec 2026-10-16-antigravity-argon § Design "Popover fold": only `.modelSpecific`
/// windows under 0.05 % fold behind "N unused windows"; a `.weekly` window always has its
/// row, at 0 % too.
final class PopoverFoldVerificationTests: XCTestCase {
    private func folds(_ kind: BucketKind, _ percent: Double, id: String = "x") -> Bool {
        PopoverView.foldsWhenUnused(Fixture.bucket(id: id, label: "L", percent: percent, kind: kind))
    }

    func testModelSpecificFoldsOnlyBelowTheThreshold() {
        XCTAssertTrue(folds(.modelSpecific, 0))
        XCTAssertTrue(folds(.modelSpecific, 0.0499))
        XCTAssertFalse(folds(.modelSpecific, 0.05))
        XCTAssertFalse(folds(.modelSpecific, 44.32))
    }

    func testModelSpecificWithANegativeOrOverflowingValueIsClampedFirst() {
        XCTAssertTrue(folds(.modelSpecific, -3))
        XCTAssertFalse(folds(.modelSpecific, 140))
    }

    func testAWeeklyWindowNeverFoldsAtAnyPercent() {
        for p in [-1.0, 0, 0.01, 0.0499, 0.05, 50, 100] {
            XCTAssertFalse(folds(.weekly, p), "weekly at \(p)")
        }
    }

    func testSevenDayKeepsItsRowWhetherWeeklyOrNot() {
        XCTAssertFalse(folds(.weekly, 0, id: "seven_day"))
    }

    func testSessionAndOtherWindowsAreNotFoldCandidates() {
        XCTAssertFalse(folds(.session, 0))
        XCTAssertFalse(folds(.other, 0))
    }

    func testTheProAntigravityWeeklySectionFoldsNothingAndTheFoldKeepsWhatItDidForClaude() {
        let pool = Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly",
                                  percent: 0, kind: .weekly)
        let argon = Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly",
                                   label: "Gemini Argon", percent: 44.32, kind: .modelSpecific)
        let sonnet = Fixture.bucket(id: "seven_day_sonnet", label: "Sonnet only", percent: 0, kind: .modelSpecific)
        let all = Fixture.bucket(id: "seven_day", label: "All models", percent: 0, kind: .weekly)
        let weekly = [pool, argon, sonnet, all]
        XCTAssertEqual(weekly.filter(PopoverView.foldsWhenUnused).map(\.id), ["seven_day_sonnet"])
        XCTAssertEqual(weekly.filter { !PopoverView.foldsWhenUnused($0) }.map(\.id), [pool.id, argon.id, "seven_day"])
    }
}
