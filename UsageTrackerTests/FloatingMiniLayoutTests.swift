import XCTest
@testable import Omelette

/// The mini window is a fixed 260 × 130 panel that never scrolls, so "which
/// windows get a row" is a rule rather than a layout accident. It lives outside
/// the view so it can be tested without a hosting window.
final class FloatingMiniLayoutTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 37, kind: .session)
    private let session2 = Fixture.bucket(id: "one_hour", label: "Hourly", percent: 5, kind: .session)
    private let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 76, kind: .weekly)
    private let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, kind: .modelSpecific)
    private let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 99, kind: .other)

    private func content(_ buckets: [UsageBucket], maxRows: Int = 2) -> FloatingMiniLayout.Content {
        FloatingMiniLayout.content(for: Fixture.snapshot(buckets: buckets), maxRows: maxRows)
    }

    // MARK: hero and rows

    func testHeroIsTheSessionWindowEvenWhenAWeeklyIsHotter() {
        // Same rule as a provider tab: the window that answers "can I keep
        // working right now" leads, whatever the weekly says.
        XCTAssertEqual(content([session, weekly]).hero?.id, "five_hour")
    }

    func testRowsAreTheRemainingWindowsWorstFirst() {
        XCTAssertEqual(content([session, opus, weekly]).rows.map(\.id), ["seven_day", "seven_day_opus"])
    }

    func testASecondSessionWindowKeepsItsSeatAgainstAHotterWeekly() {
        // The 5-hour-style windows are the numbers people check; a calm one must
        // not lose its row to a weekly that happens to be higher.
        XCTAssertEqual(content([session, session2, weekly]).rows.map(\.id), ["one_hour", "seven_day"])
    }

    func testNoMoreThanTwoRowsFit() {
        let extra = Fixture.bucket(id: "monthly", label: "Monthly", percent: 40, kind: .other)
        XCTAssertEqual(content([session, weekly, opus, extra]).rows.count, 2)
    }

    func testPromotionalPoolsNeverTakeARow() {
        // A free bonus pool at 99% costs nothing to run dry, so it never displaces
        // a real limit in two rows of space.
        XCTAssertEqual(content([session, promo, weekly]).rows.map(\.id), ["seven_day"])
    }

    func testTheHeroIsNeverRepeatedAsARow() {
        XCTAssertEqual(content([weekly, opus]).hero?.id, "seven_day")
        XCTAssertEqual(content([weekly, opus]).rows.map(\.id), ["seven_day_opus"])
    }

    // MARK: empty states

    func testNoSnapshotYetSaysLoading() {
        let content = FloatingMiniLayout.content(for: nil)
        XCTAssertNil(content.hero)
        XCTAssertTrue(content.rows.isEmpty)
        XCTAssertEqual(content.emptyText, "Loading…")
    }

    func testAServiceWithoutWindowsNamesItself() {
        let content = FloatingMiniLayout.content(for: Fixture.snapshot(id: "claude", buckets: []))
        XCTAssertNil(content.hero)
        XCTAssertEqual(content.emptyText, "You haven't used Claude yet")
    }

    func testAServiceWithWindowsHasNoEmptyText() {
        XCTAssertNil(content([session]).emptyText)
    }

    // MARK: agents count

    func testNoSessionsMeansNoAgentsCount() {
        XCTAssertNil(FloatingMiniLayout.agents([]))
    }

    func testWorkingSessionsAreCountedAndBlue() {
        let look = FloatingMiniLayout.agents([
            Fixture.agentSession(sessionID: "a", state: .working),
            Fixture.agentSession(sessionID: "b", state: .working),
            Fixture.agentSession(sessionID: "c", state: .idle),
        ])
        XCTAssertEqual(look?.dot, OMAgentColor.working)
        XCTAssertEqual(look?.text, "2")
    }

    func testAWaitingSessionOutranksTheWorkingOnes() {
        let look = FloatingMiniLayout.agents([
            Fixture.agentSession(sessionID: "a", state: .needsYou),
            Fixture.agentSession(sessionID: "b", state: .working),
        ])
        XCTAssertEqual(look?.dot, OMAgentColor.needsYou)
        XCTAssertEqual(look?.text, "1 needs you")
    }

    func testQuietSessionsShowTheTotal() {
        let look = FloatingMiniLayout.agents([
            Fixture.agentSession(sessionID: "a", state: .idle),
            Fixture.agentSession(sessionID: "b", state: .done),
        ])
        XCTAssertEqual(look?.dot, OMAgentColor.idle)
        XCTAssertEqual(look?.text, "2")
    }
}
