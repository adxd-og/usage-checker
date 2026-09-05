import XCTest
@testable import Omelette

/// The menu bar has room for a bar and two digits. Everything else it has to say
/// goes in this line — the status item's tooltip and VoiceOver read it.
final class MenuBarLabelTextTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testALiveProviderKeepsThePlainWording() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "seven_day", percent: 62.4, kind: .weekly)]
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40),
                              calendar: calendar, locale: locale),
            "Claude usage 62%"
        )
    }

    func testARetainedProviderSaysWhenAndWhy() {
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62, kind: .weekly)],
            state: .notRunning,
            stateMessage: "Antigravity isn't running",
            at: moment(day: 5, hour: 14, minute: 5)
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40),
                              calendar: calendar, locale: locale),
            "Antigravity: last known 62% (as of 14:05) — Not running"
        )
    }

    func testYesterdaysReadingCarriesItsDay() {
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62, kind: .weekly)],
            state: .notRunning,
            at: moment(day: 5, hour: 14, minute: 5)
        )
        let text = MenuBarLabel.text(for: service, now: moment(day: 6, hour: 9, minute: 0),
                                     calendar: calendar, locale: locale)
        XCTAssertTrue(text.contains("(as of "), text)
        XCTAssertFalse(text.contains("(as of 14:05)"), "a stamp with no day is a lie about yesterday: \(text)")
    }
}
