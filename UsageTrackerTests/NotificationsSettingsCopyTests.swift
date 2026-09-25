import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "Notifications: limits (80 / 95 steppers),
/// session timing, agent alerts (moved from Agents), quiet hours, daily summary"
/// (`Settings-Notifications.dc.html`). The ranges and choices are 2.x's.
final class NotificationsSettingsCopyTests: XCTestCase {
    func testHoursAreTwoDigitsOnTheHour() {
        XCTAssertEqual(NotificationsSettingsCopy.hour(0), "00:00")
        XCTAssertEqual(NotificationsSettingsCopy.hour(9), "09:00")
        XCTAssertEqual(NotificationsSettingsCopy.hour(23), "23:00")
    }

    func testThePickersOfferEveryHour() {
        XCTAssertEqual(NotificationsSettingsCopy.hours, Array(0..<24))
    }

    func testTheDailySummaryRowNamesItsHour() {
        XCTAssertEqual(NotificationsSettingsCopy.dailySummaryTitle(hour: 9), "Daily summary at 09:00")
    }

    func testTheLeadTimesAreThe2xChoices() {
        XCTAssertEqual(NotificationsSettingsCopy.leadOptions, [
            .init(minutes: 15, label: "15 min"),
            .init(minutes: 30, label: "30 min"),
            .init(minutes: 45, label: "45 min"),
            .init(minutes: 60, label: "1 hour"),
        ])
    }

    func testTheStepperRangesAreThe2xOnes() {
        XCTAssertEqual(NotificationsSettingsCopy.firstWarningRange, 50...90)
        XCTAssertEqual(NotificationsSettingsCopy.firstWarningStep, 5)
        XCTAssertEqual(NotificationsSettingsCopy.finalWarningRange, 80...99)
        XCTAssertEqual(NotificationsSettingsCopy.finalWarningStep, 1)
    }

    @MainActor
    func testTheDefaultsAreChoicesThePageOffers() {
        XCTAssertTrue(NotificationsSettingsCopy.firstWarningRange.contains(SettingsStore.Defaults.threshold80))
        XCTAssertTrue(NotificationsSettingsCopy.finalWarningRange.contains(SettingsStore.Defaults.threshold95))
        XCTAssertTrue(NotificationsSettingsCopy.leadOptions.map(\.minutes).contains(SettingsStore.Defaults.paceAlertLeadMinutes))
    }

    func testTheRowsReadAsTheMockup() {
        XCTAssertEqual(NotificationsSettingsCopy.limitsHeader, "Limits")
        XCTAssertEqual(NotificationsSettingsCopy.limitsTitle, "Notify when limits get close")
        XCTAssertEqual(NotificationsSettingsCopy.firstWarningTitle, "First warning")
        XCTAssertEqual(NotificationsSettingsCopy.finalWarningTitle, "Final warning")
        XCTAssertEqual(NotificationsSettingsCopy.limitsFooter, "One notification per window when it crosses a threshold.")
        XCTAssertEqual(NotificationsSettingsCopy.timingHeader, "Session timing")
        XCTAssertEqual(NotificationsSettingsCopy.paceTitle, "Warn when the session is burning fast")
        XCTAssertEqual(NotificationsSettingsCopy.paceCaption, "Only when you'd hit the limit before the window resets.")
        XCTAssertEqual(NotificationsSettingsCopy.leadTitle, "Warn this far ahead")
        XCTAssertEqual(NotificationsSettingsCopy.resetTitle, "Tell me when the window is about to reset")
        XCTAssertEqual(NotificationsSettingsCopy.agentsHeader, "Agents")
        XCTAssertEqual(NotificationsSettingsCopy.needsYouTitle, "When an agent needs you")
        XCTAssertEqual(NotificationsSettingsCopy.bypassQuietTitle, "Even during quiet hours")
        XCTAssertEqual(NotificationsSettingsCopy.doneTitle, "When an agent finishes a turn")
        XCTAssertEqual(NotificationsSettingsCopy.quietHeader, "Quiet hours and summary")
        XCTAssertEqual(NotificationsSettingsCopy.quietTitle, "Silence notifications at night")
        XCTAssertEqual(NotificationsSettingsCopy.quietFromTitle, "From")
        XCTAssertEqual(NotificationsSettingsCopy.quietTo, "to")
        XCTAssertEqual(NotificationsSettingsCopy.quietFromLabel, "Quiet hours from")
        XCTAssertEqual(NotificationsSettingsCopy.quietToLabel, "Quiet hours to")
    }

    /// The 2.x captions the mockup cut to one line survive as hover help.
    func testThe2xCaptionsSurviveAsHelp() {
        XCTAssertTrue(NotificationsSettingsCopy.paceHelp.contains("a pace that resets in time isn't a problem"))
        XCTAssertTrue(NotificationsSettingsCopy.resetHelp.contains("last 15 minutes"))
        XCTAssertTrue(NotificationsSettingsCopy.needsYouHelp.contains("ignores quiet hours by default"))
        XCTAssertTrue(NotificationsSettingsCopy.doneHelp.contains("fire on every reply"))
        XCTAssertTrue(NotificationsSettingsCopy.quietHelp.contains("suppressed during quiet hours"))
    }
}
