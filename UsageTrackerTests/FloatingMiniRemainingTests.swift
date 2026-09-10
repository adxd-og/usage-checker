import XCTest
@testable import Omelette

/// The 260 × 130 floating panel: a ring and two bar rows, each with a number at the
/// end. Spec § "Surfaces that switch" — "Floating mini window: FloatingMiniLayout /
/// FloatingWindow".
final class FloatingMiniRemainingTests: XCTestCase {
    private let session = Fixture.bucket(
        id: "five_hour", label: "Current session", percent: 37, kind: .session
    )
    private let weekly = Fixture.bucket(
        id: "seven_day", label: "All models", percent: 76, kind: .weekly
    )

    func testARowsNumberFollowsTheSwitch() {
        XCTAssertEqual(FloatingMiniLayout.rowPercentText(weekly, mode: .used), "76%")
        XCTAssertEqual(FloatingMiniLayout.rowPercentText(weekly, mode: .remaining), "24%")
    }

    func testTheHerosSpokenLineFollowsTheSwitch() {
        XCTAssertEqual(
            FloatingMiniLayout.heroAccessibilityLabel(session, mode: .used),
            "Current session, 37 percent used"
        )
        XCTAssertEqual(
            FloatingMiniLayout.heroAccessibilityLabel(session, mode: .remaining),
            "Current session, 63 percent left"
        )
    }

    func testARowsSpokenLineFollowsTheSwitch() {
        XCTAssertEqual(
            FloatingMiniLayout.rowAccessibilityLabel(weekly, mode: .remaining),
            "All models, 24 percent left"
        )
    }

    func testARowKeepsItsFullLabelWhileTheRingRowShortensIt() {
        // The row's own text is shortened for a 62 pt column; the spoken line is not.
        XCTAssertEqual(WindowRanking.shortWindowLabel(weekly.label), "All")
        XCTAssertTrue(FloatingMiniLayout.rowAccessibilityLabel(weekly, mode: .used).hasPrefix("All models,"))
    }

    func testWhichWindowsGetASeatIsStillDecidedByUsage() {
        // Two rows fit. Ranking is about usage: the busiest window keeps its seat
        // whichever way its number is printed.
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                session,
                weekly,
                Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 3, kind: .modelSpecific),
            ]
        )
        let content = FloatingMiniLayout.content(for: service)
        XCTAssertEqual(content.hero?.id, "five_hour")
        XCTAssertEqual(content.rows.map(\.id), ["seven_day", "seven_day_opus"])
    }
}
