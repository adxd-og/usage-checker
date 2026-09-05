import XCTest
@testable import Omelette

/// Independent verification of `MenuBarLabel.text(for:)`, focused on percent
/// rounding edges and the exact tooltip wording the spec pins ("last known 62 %
/// (as of 14:05) — Not running").
final class MenuBarLabelVerificationTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testPercentRoundsHalfUpForALiveService() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "seven_day", percent: 61.5, kind: .weekly)]
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40), calendar: calendar, locale: locale),
            "Claude usage 62%"
        )
    }

    func testPercentClampsAtOneHundredNotOverflowing() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "seven_day", percent: 137, kind: .weekly)]
        )
        let text = MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40), calendar: calendar, locale: locale)
        XCTAssertEqual(text, "Claude usage 100%", "headlinePercent's own clamp should keep the tooltip sane: \(text)")
    }

    func testRetainedTooltipMatchesTheSpecsExactWording() {
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62.4, kind: .weekly)],
            state: .notRunning,
            stateMessage: "Antigravity isn't running",
            at: moment(day: 5, hour: 14, minute: 5)
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40), calendar: calendar, locale: locale),
            "Antigravity: last known 62% (as of 14:05) — Not running"
        )
    }

    func testRetainedTooltipUsesTheStatesOwnChipWordForNotSignedIn() {
        let service = Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "five_hour", percent: 10, kind: .session)],
            state: .notSignedIn,
            at: moment(day: 5, hour: 14, minute: 5)
        )
        let text = MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40), calendar: calendar, locale: locale)
        XCTAssertTrue(text.hasSuffix("— Sign in"), "the tooltip must use the state's own chip word: \(text)")
    }
}
