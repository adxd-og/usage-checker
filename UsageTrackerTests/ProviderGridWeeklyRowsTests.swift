import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3, decisions moved out of views: which weekly rows a
/// provider page shows. Windows in use and every `.weekly` window keep their rows; two or
/// more untouched model-specific windows fold behind "N unused windows", one shows
/// inline; the hero never repeats as a row.
final class ProviderGridWeeklyRowsTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 34, kind: .session)
    private let allModels = Fixture.bucket(id: "seven_day", label: "All models", percent: 76, kind: .weekly)
    private let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, kind: .modelSpecific)
    private let sonnet = Fixture.bucket(id: "seven_day_sonnet", label: "Sonnet only", percent: 0, kind: .modelSpecific)
    private let cowork = Fixture.bucket(id: "seven_day_cowork", label: "Cowork", percent: 0, kind: .modelSpecific)

    private func rows(_ buckets: [UsageBucket], unfolded: Bool = false) -> ProviderGridRules.WeeklyRows {
        let service = Fixture.snapshot(id: "claude", buckets: buckets)
        return ProviderGridRules.weeklyRows(for: service, hero: WindowRanking.detailHero(for: service), showsUnused: unfolded)
    }

    func testTwoUntouchedWindowsFoldBehindTheToggle() {
        let folded = rows([session, allModels, opus, sonnet, cowork])
        XCTAssertEqual(folded.shown.map(\.id), ["seven_day", "seven_day_opus"])
        XCTAssertEqual(folded.unusedCount, 2)
        XCTAssertTrue(folded.showsToggle)
    }

    func testUnfoldedTheUntouchedWindowsFollowTheRest() {
        XCTAssertEqual(
            rows([session, allModels, opus, sonnet, cowork], unfolded: true).shown.map(\.id),
            ["seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_cowork"]
        )
    }

    func testASingleUntouchedWindowShowsInlineWithoutAToggle() {
        let single = rows([session, allModels, sonnet])
        XCTAssertEqual(single.shown.map(\.id), ["seven_day", "seven_day_sonnet"])
        XCTAssertEqual(single.unusedCount, 1)
        XCTAssertFalse(single.showsToggle)
    }

    func testTheHeroNeverRepeatsAsARow() {
        // No session: the all-models weekly is the hero.
        XCTAssertEqual(rows([allModels, opus]).shown.map(\.id), ["seven_day_opus"])
    }

    func testAWeeklyWindowAtZeroKeepsItsRow() {
        let untouchedWeek = Fixture.bucket(id: "seven_day", label: "All models", percent: 0, kind: .weekly)
        let result = rows([session, untouchedWeek])
        XCTAssertEqual(result.shown.map(\.id), ["seven_day"])
        XCTAssertEqual(result.unusedCount, 0)
    }

    func testSessionAndOtherWindowsAreNotWeeklyRows() {
        let other = Fixture.bucket(id: "grok_credits", label: "Credits", percent: 17)
        XCTAssertEqual(rows([session, other]).shown, [])
    }

    func testTheFoldSaysHowManyAndHowToHideThem() {
        XCTAssertEqual(PopoverCopy.unusedWindowsToggle(count: 2, unfolded: false), "2 unused windows")
        XCTAssertEqual(PopoverCopy.unusedWindowsToggle(count: 5, unfolded: false), "5 unused windows")
        XCTAssertEqual(PopoverCopy.unusedWindowsToggle(count: 2, unfolded: true), "Hide unused windows")
    }
}
