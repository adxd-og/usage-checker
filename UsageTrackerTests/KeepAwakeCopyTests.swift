import XCTest
@testable import Omelette

/// Keep-awake spec 2026-10-26, § UI (popover block, menu bar) and § Behaviour (Visible,
/// One-time setup): every word the block, the marker and the tooltip show, and the rules
/// that pick them.
final class KeepAwakeCopyTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)

    // MARK: - Words

    func testTheBlockReadsAsTheSpec() {
        XCTAssertEqual(KeepAwakeCopy.title, "Keep awake with the lid closed")
        XCTAssertEqual(KeepAwakeCopy.applyButton, "Apply")
        XCTAssertEqual(KeepAwakeCopy.cancelButton, "Cancel")
        XCTAssertEqual(KeepAwakeCopy.dismissButton, "Dismiss")
        XCTAssertEqual(KeepAwakeCopy.openLoginItemsButton, "Open Login Items")
    }

    /// § Behaviour, One-time setup; P1 tester finding S6: the text names macOS's notice
    /// and the switch, and says the approval arms nothing by itself.
    func testTheApprovalTextNamesTheNoticeAndTheSwitch() {
        XCTAssertEqual(
            KeepAwakeCopy.approvalText,
            "Omelette's helper needs your approval once. macOS announces it as “Background Items Added”: switch Omelette on in System Settings › General › Login Items & Extensions, then press Apply again."
        )
    }

    /// § Behaviour, Timed only: d 0–7, h 0–23, m 0–59.
    func testTheSteppersCarryTheirUnitsAndRanges() {
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.allCases, [.days, .hours, .minutes])
        XCTAssertEqual(KeepAwakeCopy.stepperValue(0, unit: .days), "0 d")
        XCTAssertEqual(KeepAwakeCopy.stepperValue(4, unit: .hours), "4 h")
        XCTAssertEqual(KeepAwakeCopy.stepperValue(30, unit: .minutes), "30 min")
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.days.name, "Days")
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.hours.name, "Hours")
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.minutes.name, "Minutes")
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.days.range, 0...7)
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.hours.range, 0...23)
        XCTAssertEqual(KeepAwakeCopy.StepperUnit.minutes.range, 0...59)
    }

    // MARK: - The countdown

    func testTheCountdownReadsHoursAndMinutes() {
        XCTAssertEqual(KeepAwakeCopy.remaining(4 * 3_600 + 52 * 60), "4 h 52 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(3 * 3_600), "3 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(45 * 60), "45 min")
    }

    /// Rounded up: a mode with 30 s left reads one minute, never "0 min" while armed.
    func testUnderAMinuteLeftStillReadsOneMinute() {
        XCTAssertEqual(KeepAwakeCopy.remaining(30), "1 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(4 * 3_600 + 51 * 60 + 30), "4 h 52 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(0), "0 min")
        XCTAssertEqual(KeepAwakeCopy.remaining(-5), "0 min")
    }

    func testBeyondADayTheCountdownDropsTheMinutes() {
        XCTAssertEqual(KeepAwakeCopy.remaining(3 * 86_400 + 2 * 3_600), "3 d 2 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(2 * 86_400 + 5 * 3_600 + 59 * 60), "2 d 5 h")
        XCTAssertEqual(KeepAwakeCopy.remaining(604_800), "7 d")
    }

    /// § UI: "Awake until 18:40 · 4 h 52 min left".
    func testTheArmedLineSaysUntilWhenAndHowLong() {
        let deadline = now.addingTimeInterval(4 * 3_600 + 52 * 60)
        XCTAssertEqual(
            KeepAwakeCopy.armedLine(deadline: deadline, now: now, calendar: calendar, locale: locale),
            "Awake until 18:40 · 4 h 52 min left"
        )
    }

    func testADeadlineOnAnotherDayNamesTheDay() {
        XCTAssertEqual(
            KeepAwakeCopy.armedLine(deadline: now.addingTimeInterval(3 * 86_400 + 3 * 3_600), now: now, calendar: calendar, locale: locale),
            "Awake until Thu 16:48 · 3 d 3 h left"
        )
        XCTAssertEqual(
            KeepAwakeCopy.armedLine(deadline: now.addingTimeInterval(604_800), now: now, calendar: calendar, locale: locale),
            "Awake until 2 Nov, 13:48 · 7 d left"
        )
    }

    // MARK: - Why it ended

    /// § UI: "Ended 14:02 · battery below 25 %"; one reason per way a mode ends.
    func testEveryEndSaysWhy() {
        let at = now.addingTimeInterval(14 * 60)       // 14:02
        let later = now.addingTimeInterval(42 * 60)    // 14:30
        func line(_ reason: KeepAwakeEndReason) -> String {
            KeepAwakeCopy.endedLine(at: at, reason: reason, now: later, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(line(.deadline), "Ended 14:02 · time is up")
        XCTAssertEqual(line(.batteryFloor), "Ended 14:02 · battery below 25 %")
        XCTAssertEqual(line(.cancelled), "Ended 14:02 · cancelled")
        XCTAssertEqual(line(.restarted), "Ended 14:02 · the Mac or the helper restarted")
        XCTAssertEqual(line(.stopped), "Ended 14:02 · the helper was stopped")
        XCTAssertEqual(KeepAwakeEndReason.allCases.count, 5, "a new reason needs its words here")
    }

    func testAnEndOnAnEarlierDayNamesTheDate() {
        let yesterday = Date(timeIntervalSince1970: 1_792_966_500)   // Sunday 2026-10-25 22:15 UTC
        XCTAssertEqual(
            KeepAwakeCopy.endedLine(at: yesterday, reason: .restarted, now: now, calendar: calendar, locale: locale),
            "Ended 25 Oct, 22:15 · the Mac or the helper restarted"
        )
    }
}
