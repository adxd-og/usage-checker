import XCTest
@testable import Omelette

/// Pins `CLICore/StatusText.swift` and `CLICore/StatusLineText.swift` — the
/// `omelette status` and status-line renderers — against a retained provider, since
/// P1 touches the same "last known" concept in the popover (`RetainedCopy`,
/// `CLICore/RetainedStamp.swift`) and both are compiled from CLICore into the CLI
/// target as well as the app (`CLICore/RetainedStamp.swift:4-8`). Neither file is in
/// the P1 diff (`git diff <merge-base>..feat/3.0-p1 -- CLICore/` is empty); these
/// tests establish that fact rather than assume it.
final class CLICoreRetainedOutputVerificationTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// `StatusText.serviceLine` still appends "(last known HH:mm)" for a retained
    /// service and nothing about the wording moved to "Last known" (the tile's own
    /// phrase, unrelated to this file).
    func testStatusTextStillWritesLastKnownInLowercaseParentheses() {
        let service = StatusSnapshot.Service(
            id: "antigravity", name: "Antigravity", state: "notRunning",
            retained: true, retainedAt: moment(25, 12, 50), plan: nil,
            windows: [StatusSnapshot.Window(id: "session", label: "Session", percent: 21, resetsAt: nil, kind: "session")]
        )
        let line = StatusText.serviceLine(service, width: service.name.count, now: moment(25, 14, 10), calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("(last known"), line)
        XCTAssertTrue(line.contains("12:50"), line)
        // Not the popover's own phrase — the two surfaces intentionally differ in
        // case and punctuation, and this file must not have picked it up.
        XCTAssertFalse(line.contains("Last known 12:50"), line)
    }

    /// `StatusLineText.windowParts` still stamps a retained window "(as of HH:mm)",
    /// `RetainedCopy.asOf`'s exact wording, untouched by P1.
    func testStatusLineTextStillStampsRetainedWindowsAsOf() {
        let service = StatusSnapshot.Service(
            id: "antigravity", name: "Antigravity", state: "notRunning",
            retained: true, retainedAt: moment(25, 12, 50), plan: nil,
            windows: [StatusSnapshot.Window(id: "session", label: "Session", percent: 21, resetsAt: moment(25, 13, 0), kind: "session")]
        )
        let parts = StatusLineText.windowParts(service, mode: .used, now: moment(25, 14, 10), calendar: calendar, locale: locale)
        XCTAssertTrue(parts.first?.contains("(as of 12:50)") ?? false, "\(parts)")
        // The reset is in the past and the window is retained: no false "resets ..." part.
        XCTAssertFalse(parts.contains { $0.hasPrefix("resets") })
    }

    /// A live (non-retained) service's window keeps a plain reading, with no stamp at all.
    func testStatusLineTextLeavesALiveWindowUnstamped() {
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok",
            retained: false, retainedAt: nil, plan: nil,
            windows: [StatusSnapshot.Window(id: "session", label: "Session", percent: 42, resetsAt: moment(25, 18, 0), kind: "session")]
        )
        let parts = StatusLineText.windowParts(service, mode: .used, now: moment(25, 14, 10), calendar: calendar, locale: locale)
        XCTAssertFalse(parts.first?.contains("as of") ?? true, "\(parts)")
    }

    /// `RelativeStamp.asOf` / `RetainedCopy.asOf` — the shared primitive both files
    /// and the popover's tile read — are unchanged: same day is bare time, an older
    /// day carries its date.
    func testRelativeStampSameDayVersusOlderDay() {
        XCTAssertEqual(RelativeStamp.asOf(moment(25, 12, 50), now: moment(25, 14, 10), calendar: calendar, locale: locale), "12:50")
        XCTAssertEqual(RetainedCopy.asOf(moment(25, 12, 50), now: moment(25, 14, 10), calendar: calendar, locale: locale), "as of 12:50")
        let older = RelativeStamp.asOf(moment(20, 12, 50), now: moment(25, 14, 10), calendar: calendar, locale: locale)
        XCTAssertTrue(older.hasSuffix(", 12:50"), older)
        XCTAssertNotEqual(older, "12:50")
    }
}
