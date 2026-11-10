import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Windows, "A window runs the calendar month before its
/// `reset_at`": a provider page heads its limit rows by how long they run. "Monthly limits" over
/// windows longer than a week (Mistral's allowances, Codex's monthly window on the free plan),
/// "Weekly limits" over week-long ones and over rows of no stated length, "Limits" over a mix.
final class LimitsHeaderCopyTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    func testWeekLongWindowsKeepTheWeeklyHeader() {
        let claude = [
            Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            Fixture.bucket(id: "seven_day_fable", label: "Fable only", percent: 24, kind: .modelSpecific),
        ]
        XCTAssertEqual(PopoverCopy.limitsHeader(for: claude), "Weekly limits")
    }

    func testMistralsMonthlyAllowancesAreHeadedMonthly() throws {
        let entries = try MistralBillingFetcher.decodeBudget(Data(MistralFixture.budgetBody.utf8))
        let api = try XCTUnwrap(MistralBudgetRules.buckets(from: entries).first { $0.id == "mistral_api" })
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [api]), "Monthly limits")
    }

    func testAThirtyDayWindowIsMonthlyWhateverItsKind() {
        let codexFree = Fixture.bucket(id: "secondary", label: "Monthly", percent: 40, kind: .weekly, windowLength: 30 * day)
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [codexFree]), "Monthly limits")
        let eightDays = Fixture.bucket(id: "secondary", label: "Weekly", percent: 40, kind: .weekly, windowLength: 8 * day)
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [eightDays]), "Weekly limits", "a week's length is up to 8 days")
    }

    func testAMixOfLengthsIsJustLimits() {
        let week = Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly)
        let month = Fixture.bucket(id: "mistral_api", label: "API", percent: 0, kind: .modelSpecific, windowLength: 30 * day)
        XCTAssertEqual(PopoverCopy.limitsHeader(for: [week, month]), "Limits")
    }
}
