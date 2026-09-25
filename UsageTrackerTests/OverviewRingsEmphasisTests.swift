import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Overview rings": hover or focus on a ring or a legend
/// row dims the others to 22 % and swaps the centre to that window's figure and name
/// (`Dashboard-Overview.dc.html`'s script: opacity 1 or 0.22). Hover is view state and is
/// never stored; the dot is explained on hover (§ Removals, no "dot = time elapsed").
final class OverviewRingsEmphasisTests: XCTestCase {
    func testAtRestEveryRingAndRowIsFullStrength() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: nil, count: 3), [1, 1, 1])
    }

    func testHoveringOneDimsTheOthersTo22Percent() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 1, count: 3), [0.22, 1, 0.22])
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 0, count: 4), [1, 0.22, 0.22, 0.22])
    }

    func testAHoverPastTheLastWindowIsAtRest() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 3, count: 3), [1, 1, 1])
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: -1, count: 2), [1, 1])
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 0, count: 0), [])
    }

    func testThePointerWinsOverKeyboardFocusAndFocusCountsOnlyFromTheKeyboard() {
        XCTAssertEqual(OverviewRingsRules.emphasised(hovered: 2, focused: 0, keyboardNavigation: true), 2)
        XCTAssertEqual(OverviewRingsRules.emphasised(hovered: nil, focused: 1, keyboardNavigation: true), 1)
        XCTAssertNil(OverviewRingsRules.emphasised(hovered: nil, focused: 1, keyboardNavigation: false))
        XCTAssertNil(OverviewRingsRules.emphasised(hovered: nil, focused: nil, keyboardNavigation: true))
    }

    func testThePointerFindsTheRingUnderIt() {
        let c = OverviewRingsRules.diameter / 2
        XCTAssertEqual(OverviewRingsRules.ring(at: CGPoint(x: c, y: c - 106), count: 3), 0)
        XCTAssertEqual(OverviewRingsRules.ring(at: CGPoint(x: c + 85, y: c), count: 3), 1)
        XCTAssertEqual(OverviewRingsRules.ring(at: CGPoint(x: c, y: c + 64), count: 3), 2)
        // Between two rings the nearer one answers: each owns half the 5 pt gap.
        XCTAssertEqual(OverviewRingsRules.ring(at: CGPoint(x: c, y: c + 75), count: 3), 1)
    }

    func testTheCentreAndARingThatIsNotDrawnAnswerNothing() {
        let c = OverviewRingsRules.diameter / 2
        XCTAssertNil(OverviewRingsRules.ring(at: CGPoint(x: c, y: c), count: 3))
        XCTAssertNil(OverviewRingsRules.ring(at: CGPoint(x: c, y: c + 40), count: 3))
        XCTAssertNil(OverviewRingsRules.ring(at: CGPoint(x: c, y: c + 64), count: 2))
    }

    func testLeavingARowClearsOnlyThatRowsHover() {
        XCTAssertEqual(OverviewRingsRules.hover(inside: true, row: 1, current: nil), 1)
        XCTAssertNil(OverviewRingsRules.hover(inside: false, row: 1, current: 1))
        XCTAssertEqual(OverviewRingsRules.hover(inside: false, row: 0, current: 1), 1)
    }

    func testTheDimmedStrengthIsTheMockups() {
        XCTAssertEqual(OverviewRingsRules.dimmedOpacity, 0.22)
    }

    func testARowsTooltipExplainsTheDot() {
        let calendar = SessionFixture.calendar
        let now = SessionFixture.now
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 53,
                                     resetsAt: now.addingTimeInterval(15 * 60), kind: .session)
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 41,
                                    resetsAt: now.addingTimeInterval(4 * 86_400 + 99 * 60), kind: .weekly)
        let credits = Fixture.bucket(id: "grok_credits", label: "Credits", percent: 30, kind: .weekly)
        XCTAssertEqual(OverviewRingsRules.help(for: session, now: now, calendar: calendar, locale: SessionFixture.locale),
                       "Current session · resets 11:35 · dot: 95% of the window elapsed")
        XCTAssertEqual(OverviewRingsRules.help(for: weekly, now: now, calendar: calendar, locale: SessionFixture.locale),
                       "All models · resets Thu 12:59 · dot: 42% of the window elapsed")
        XCTAssertEqual(OverviewRingsRules.help(for: credits, now: now, calendar: calendar, locale: SessionFixture.locale),
                       "Credits")
    }
}
