import XCTest
@testable import Omelette

/// The status line for a provider that stopped reporting. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Status
/// line: a retained provider keeps its window but the text says how old it is (via
/// `RetainedCopy`), and the `resets …` part is dropped once `resetsAt <= now`. Today's
/// dollars stay." status.json is rewritten every poll, so the file is always fresh; the
/// retained flag is the only thing that can tell the line its numbers are old.
final class StatusLineRetainedTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func window(_ percent: Double, resetsIn: TimeInterval?) -> StatusSnapshot.Window {
        StatusSnapshot.Window(
            id: "five_hour", label: "Session", percent: percent,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: "session"
        )
    }

    private func retained(
        at retainedAt: Date?, windows: [StatusSnapshot.Window], todayCost: Double? = nil
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true, retainedAt: retainedAt,
            windows: windows, todayCost: todayCost,
            // Pay-as-you-go dollars: no API-equivalent marker is in play on this line.
            apiEquivalent: todayCost == nil ? nil : false
        )
    }

    private func line(_ service: StatusSnapshot.Service, showsRemaining: Bool = false) -> String {
        StatusLineText.render(
            snapshot: StatusSnapshot(
                version: StatusSnapshot.currentVersion, updatedAt: now, services: [service],
                agents: .none, showsRemaining: showsRemaining
            ),
            now: now, colour: false, calendar: calendar, locale: locale
        )
    }

    func testARetainedNumberSaysHowOldItIs() {
        XCTAssertEqual(
            line(retained(at: now.addingTimeInterval(-3600), windows: [window(62, resetsIn: 40 * 60)])),
            "◐ 62% (as of 10:20) · resets in 40m"
        )
    }

    func testARetainedWindowPastItsResetDropsTheReset() {
        // What the verifier's scratch run printed: "◐ 95% · resets now", five hours after
        // that window had started over.
        XCTAssertEqual(
            line(retained(at: now.addingTimeInterval(-6 * 3600), windows: [window(95, resetsIn: -5 * 3600)])),
            "◐ 95% (as of 05:20)"
        )
    }

    func testAResetExactlyNowIsAlreadyPast() {
        XCTAssertEqual(
            line(retained(at: now.addingTimeInterval(-3600), windows: [window(95, resetsIn: 0)])),
            "◐ 95% (as of 10:20)"
        )
    }

    func testARetainedWindowWithNoResetKeepsJustItsStamp() {
        XCTAssertEqual(
            line(retained(at: now.addingTimeInterval(-3600), windows: [window(62, resetsIn: nil)])),
            "◐ 62% (as of 10:20)"
        )
    }

    func testYesterdaysReadingCarriesItsDay() {
        let at = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 22, minute: 10))!
        let text = line(retained(at: at, windows: [window(62, resetsIn: 40 * 60)]))
        XCTAssertEqual(
            text,
            "◐ 62% (\(RetainedCopy.asOf(at, now: now, calendar: calendar, locale: locale))) · resets in 40m"
        )
        XCTAssertFalse(text.contains("(as of 22:10)"), text)
    }

    func testTodaysDollarsStay() {
        let text = line(retained(
            at: now.addingTimeInterval(-3600), windows: [window(62, resetsIn: 40 * 60)], todayCost: 4.2
        ))
        XCTAssertTrue(text.hasPrefix("◐ 62% (as of 10:20) · resets in 40m · $4.20 today"), text)
    }

    func testAFileWithoutAStampStillSaysLastKnown() {
        XCTAssertEqual(
            line(retained(at: nil, windows: [window(62, resetsIn: 40 * 60)])),
            "◐ 62% (last known) · resets in 40m"
        )
    }

    func testCountingDownKeepsTheStamp() {
        XCTAssertEqual(
            line(
                retained(at: now.addingTimeInterval(-3600), windows: [window(62, resetsIn: 40 * 60)]),
                showsRemaining: true
            ),
            "◐ 38% left (as of 10:20) · resets in 40m"
        )
    }

    func testALiveWindowJustPastItsResetStillSaysResetsNow() {
        // Seconds past, and the next poll replaces it: the live line is unchanged
        // (StatusLineTextTests.testAWindowPastItsResetSaysSo pins the same).
        let live = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, windows: [window(98, resetsIn: -5)]
        )
        XCTAssertEqual(line(live), "◐ 98% · resets now")
    }

    func testAProviderWithNoWindowHasNoGauge() {
        XCTAssertEqual(
            StatusLineText.windowParts(
                retained(at: now, windows: []), mode: .used, now: now, calendar: calendar, locale: locale
            ),
            []
        )
    }
}
