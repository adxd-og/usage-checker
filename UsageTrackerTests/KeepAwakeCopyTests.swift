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

    /// § UI: the block's three number fields and what VoiceOver reads for them.
    func testTheFieldsCarryTheirUnitsAndNames() {
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.allCases, [.days, .hours, .minutes])
        XCTAssertEqual(KeepAwakeCopy.unitValue(0, unit: .days), "0 d")
        XCTAssertEqual(KeepAwakeCopy.unitValue(4, unit: .hours), "4 h")
        XCTAssertEqual(KeepAwakeCopy.unitValue(30, unit: .minutes), "30 min")
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.days.name, "Days")
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.hours.name, "Hours")
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.minutes.name, "Minutes")
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

    // MARK: - Which line the block shows

    func testNothingArmedShowsNoLine() {
        XCTAssertEqual(KeepAwakeCopy.status(registration: .notRegistered, state: .idle, dismissedThrough: 0, now: now), .idle)
        XCTAssertEqual(KeepAwakeCopy.status(registration: .ready, state: .idle, dismissedThrough: 0, now: now), .idle)
    }

    func testAnArmedModeShowsItsDeadline() {
        let deadline = now.addingTimeInterval(3_600)
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .ready, state: .armed(deadline: deadline, floorEnabled: true), dismissedThrough: 0, now: now),
            .armed(deadline: deadline)
        )
    }

    /// § Behaviour, Visible: the local countdown ends the mode on screen at its deadline,
    /// before the helper's next answer.
    func testAModePastItsDeadlineReadsAsEndedBeforeTheHelperSaysSo() {
        let deadline = now.addingTimeInterval(-1)
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .ready, state: .armed(deadline: deadline, floorEnabled: true), dismissedThrough: 0, now: now),
            .ended(at: deadline, reason: .deadline)
        )
    }

    /// The helper keeps reporting `ended`; Dismiss (or Apply) hides every end up to that moment.
    func testAnEndShowsUntilItIsDismissed() {
        let at = now.addingTimeInterval(-600)
        let ended = KeepAwakeState.ended(at: at, reason: .batteryFloor)
        XCTAssertEqual(KeepAwakeCopy.status(registration: .ready, state: ended, dismissedThrough: 0, now: now), .ended(at: at, reason: .batteryFloor))
        XCTAssertEqual(KeepAwakeCopy.status(registration: .ready, state: ended, dismissedThrough: at.timeIntervalSince1970, now: now), .idle)
        XCTAssertEqual(KeepAwakeCopy.status(registration: .ready, state: ended, dismissedThrough: now.addingTimeInterval(-60).timeIntervalSince1970, now: now), .idle)
    }

    func testALaterEndShowsAgainAfterADismiss() {
        let at = now.addingTimeInterval(-600)
        XCTAssertEqual(
            KeepAwakeCopy.status(registration: .ready, state: .ended(at: at, reason: .deadline), dismissedThrough: now.addingTimeInterval(-1_200).timeIntervalSince1970, now: now),
            .ended(at: at, reason: .deadline)
        )
    }

    /// § Behaviour, One-time setup: "until it is approved, the block says so".
    func testAHelperAwaitingApprovalSaysSo() {
        XCTAssertEqual(KeepAwakeCopy.status(registration: .requiresApproval, state: .idle, dismissedThrough: 0, now: now), .approval)
    }

    /// The helper switched off in Login Items while armed: why it ended first, then how to
    /// switch it back on.
    func testAnEndComesBeforeTheApprovalText() {
        let at = now.addingTimeInterval(-300)
        let stopped = KeepAwakeState.ended(at: at, reason: .stopped)
        XCTAssertEqual(KeepAwakeCopy.status(registration: .requiresApproval, state: stopped, dismissedThrough: 0, now: now), .ended(at: at, reason: .stopped))
        XCTAssertEqual(KeepAwakeCopy.status(registration: .requiresApproval, state: stopped, dismissedThrough: now.timeIntervalSince1970, now: now), .approval)
    }

    /// § UI: Apply is disabled when `KeepAwakeRules.duration` has no duration (zero, negatives),
    /// and while a call is in flight; over the ceiling it applies the ceiling.
    func testApplyNeedsADurationAndNoCallInFlight() {
        XCTAssertFalse(KeepAwakeCopy.canApply(days: 0, hours: 0, minutes: 0, isWorking: false))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 0, hours: 0, minutes: 1, isWorking: false))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 7, hours: 23, minutes: 59, isWorking: false))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 8, hours: 0, minutes: 0, isWorking: false))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 7, hours: 0, minutes: 0, isWorking: false))
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 0, hours: 0, minutes: 90, isWorking: false))
        XCTAssertFalse(KeepAwakeCopy.canApply(days: 0, hours: 1, minutes: 0, isWorking: true))
    }

    /// § UI: a field is read as typed — digits only, nothing else counts, nine digits at most.
    func testAFieldIsReadAsTypedDigitsOnly() {
        XCTAssertEqual(KeepAwakeCopy.fieldNumber(""), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber(" 8 "), 8)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("007"), 7)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("1.5"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("1,5"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("-1"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("abc"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("٨"), 0)
        XCTAssertEqual(KeepAwakeCopy.fieldNumber("99999999999999999999"), 999_999_999)
        XCTAssertEqual(KeepAwakeRules.duration(days: KeepAwakeCopy.fieldNumber("99999999999999999999"), hours: 0, minutes: 0), 691_140)
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: KeepAwakeCopy.fieldNumber("8"), hours: 0, minutes: 0), KeepAwakeCopy.limitNotice)
    }

    /// Fool-proofing: a field stops at 7 / 24 / 60, refuses anything but digits, keeps
    /// what was there, and the total rule still has the last word at 7 d 24 h (the line, then the ceiling).
    func testAFieldStopsAtItsOwnMaximumAndRefusesAnythingButDigits() {
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.days.maximum, 7)
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.hours.maximum, 24)
        XCTAssertEqual(KeepAwakeCopy.DurationUnit.minutes.maximum, 60)
        XCTAssertEqual(KeepAwakeCopy.fieldText("230", previous: "23", unit: .hours), "24")
        XCTAssertEqual(KeepAwakeCopy.fieldText("8", previous: "", unit: .days), "7")
        XCTAssertEqual(KeepAwakeCopy.fieldText("61", previous: "6", unit: .minutes), "60")
        XCTAssertEqual(KeepAwakeCopy.fieldText("60", previous: "6", unit: .minutes), "60")
        XCTAssertEqual(KeepAwakeCopy.fieldText("", previous: "5", unit: .days), "")
        XCTAssertEqual(KeepAwakeCopy.fieldText("1.5", previous: "1", unit: .hours), "1")
        XCTAssertEqual(KeepAwakeCopy.fieldText("-1", previous: "", unit: .minutes), "")
        XCTAssertEqual(KeepAwakeCopy.fieldText("007", previous: "", unit: .days), "7")
        XCTAssertEqual(KeepAwakeCopy.fieldText(" 5 ", previous: "", unit: .hours), "5")
        XCTAssertEqual(KeepAwakeCopy.fieldText("99999999999", previous: "", unit: .minutes), "60")
        XCTAssertEqual(KeepAwakeCopy.fieldText("٨", previous: "3", unit: .days), "3")
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 7, hours: 24, minutes: 0), KeepAwakeCopy.limitNotice)
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 7, hours: 23, minutes: 60), KeepAwakeCopy.limitNotice)
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 6, hours: 24, minutes: 60))
    }

    /// § UI: a typed total over the ceiling gets one line saying Apply brings it down; nothing else gets a line.
    func testOverSevenDaysTheBlockSaysWhyAndNothingElseDoes() {
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 8, hours: 0, minutes: 0), "Up to 7 d 23 h 59 min, for your safety. Apply sets that.")
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 7, hours: 23, minutes: 60), KeepAwakeCopy.limitNotice)
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 7, hours: 24, minutes: 0), KeepAwakeCopy.limitNotice)
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 0, hours: 0, minutes: 11_520), KeepAwakeCopy.limitNotice)
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 0, hours: 192, minutes: 0), KeepAwakeCopy.limitNotice)
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: Int.max, hours: 1, minutes: Int.max), KeepAwakeCopy.limitNotice)
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 7, hours: 0, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 7, hours: 23, minutes: 59))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 6, hours: 25, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 0, hours: 0, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: -1, hours: 0, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 0, hours: 30, minutes: 0))
    }

    /// Owner 2026-10-27: Apply adapts. Over the ceiling the rule hands back the ceiling and
    /// the block says so; the canonical form is what the fields show afterwards.
    func testOverTheCeilingApplyUsesTheCeilingAndTheFieldsComeBackCanonical() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 24, minutes: 60), 691_140)
        XCTAssertTrue(KeepAwakeCopy.canApply(days: 7, hours: 24, minutes: 60, isWorking: false))
        XCTAssertEqual(KeepAwakeCopy.entryNotice(days: 7, hours: 24, minutes: 60), "Up to 7 d 23 h 59 min, for your safety. Apply sets that.")
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 11_519), KeepAwakeRules.Parts(days: 7, hours: 23, minutes: 59))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: Int(KeepAwakeRules.duration(days: 0, hours: 24, minutes: 60)! / 60)), KeepAwakeRules.Parts(days: 1, hours: 1, minutes: 0))
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 0))
        XCTAssertNil(KeepAwakeCopy.entryNotice(days: 7, hours: 23, minutes: 59))
    }

    /// The rounded-up minute changes on the deadline's own minute grid; the block ticks there.
    func testTheCountdownTicksOnTheDeadlinesMinutes() {
        let deadline = now.addingTimeInterval(4 * 3_600 + 51 * 60 + 30)
        XCTAssertEqual(KeepAwakeCopy.tickAnchor(deadline: deadline, now: now), now.addingTimeInterval(-30))
        XCTAssertEqual(KeepAwakeCopy.tickAnchor(deadline: now.addingTimeInterval(600), now: now), now)
        XCTAssertEqual(KeepAwakeCopy.tickAnchor(deadline: nil, now: now), now)
        XCTAssertEqual(KeepAwakeCopy.tickAnchor(deadline: now.addingTimeInterval(-100), now: now), now.addingTimeInterval(-100))
    }

    // MARK: - Menu bar

    /// § UI, Menu bar: "The tooltip's first line says 'Keep awake until 18:40'".
    func testTheTooltipLineSaysUntilWhen() {
        XCTAssertEqual(
            KeepAwakeCopy.tooltipLine(.armed(deadline: now.addingTimeInterval(4 * 3_600 + 52 * 60), floorEnabled: true), now: now, calendar: calendar, locale: locale),
            "Keep awake until 18:40"
        )
        XCTAssertEqual(
            KeepAwakeCopy.tooltipLine(.armed(deadline: now.addingTimeInterval(3 * 86_400 + 3 * 3_600), floorEnabled: false), now: now, calendar: calendar, locale: locale),
            "Keep awake until Thu 16:48"
        )
        XCTAssertNil(KeepAwakeCopy.tooltipLine(.idle, now: now, calendar: calendar, locale: locale))
        XCTAssertNil(KeepAwakeCopy.tooltipLine(.ended(at: now, reason: .cancelled), now: now, calendar: calendar, locale: locale))
        XCTAssertNil(KeepAwakeCopy.tooltipLine(.armed(deadline: now, floorEnabled: true), now: now, calendar: calendar, locale: locale))
    }

    /// § UI, Menu bar: a marker while armed, none otherwise; the local countdown drops it
    /// at the deadline (§ Behaviour, Visible).
    func testTheMarkerShowsOnlyWhileArmed() {
        XCTAssertEqual(KeepAwakeCopy.menuBarMarker(.armed(deadline: now.addingTimeInterval(60), floorEnabled: true), now: now), "☾")
        XCTAssertNil(KeepAwakeCopy.menuBarMarker(.idle, now: now))
        XCTAssertNil(KeepAwakeCopy.menuBarMarker(.ended(at: now, reason: .batteryFloor), now: now))
        XCTAssertNil(KeepAwakeCopy.menuBarMarker(.armed(deadline: now, floorEnabled: true), now: now))
    }
}
