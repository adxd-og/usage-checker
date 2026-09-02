import XCTest
@testable import Omelette

/// `SettingsStore` writes to the host app's real preferences domain, so the whole
/// domain is captured before each test and put back afterwards — a test must not
/// leave the user's settings reset.
/// Not `@MainActor` at class level: XCTest's `setUp`/`tearDown` are nonisolated, so
/// only the bodies that touch `SettingsStore` are hopped onto the main actor.
final class SettingsStoreTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String {
        Bundle.main.bundleIdentifier ?? "com.usagetracker.app"
    }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        UserDefaults.standard.setPersistentDomain(savedDomain ?? [:], forName: domainName)
        super.tearDown()
    }

    /// Every stored setting moved off its default, so a `resetToDefaults()` that
    /// forgets one leaves a visible difference.
    @MainActor
    private func scrambleEverything(_ s: SettingsStore) {
        s.refreshIntervalSeconds = 300
        s.anthropicBetaHeader = "oauth-1999-01-01"
        s.preferAdminWhenAvailable = !SettingsStore.Defaults.preferAdminWhenAvailable
        s.codexProviderEnabled = !SettingsStore.Defaults.codexProviderEnabled
        s.geminiProviderEnabled = !SettingsStore.Defaults.geminiProviderEnabled
        s.antigravityProviderEnabled = !SettingsStore.Defaults.antigravityProviderEnabled
        s.grokProviderEnabled = !SettingsStore.Defaults.grokProviderEnabled
        s.claudeWeeklyBudgetUSD = 250
        s.notificationsEnabled = !SettingsStore.Defaults.notificationsEnabled
        s.threshold80 = 55
        s.threshold95 = 99
        s.paceAlertsEnabled = !SettingsStore.Defaults.paceAlertsEnabled
        s.paceAlertLeadMinutes = 15
        s.resetAlertsEnabled = !SettingsStore.Defaults.resetAlertsEnabled
        s.quietHoursEnabled = !SettingsStore.Defaults.quietHoursEnabled
        s.quietHoursStart = 3
        s.quietHoursEnd = 4
        s.dailySummaryEnabled = !SettingsStore.Defaults.dailySummaryEnabled
        s.dailySummaryHour = 17
        s.lastDailySummaryDay = "2026-01-01T00:00:00Z"
        s.menuBarHiddenServicesRaw = "codex,gemini"
        s.menuBarNumberMode = .never
        s.hasSeenOnboarding = !SettingsStore.Defaults.hasSeenOnboarding
        s.agentsNotifyNeedsYou = !SettingsStore.Defaults.agentsNotifyNeedsYou
        s.agentsNeedsYouBypassQuietHours = !SettingsStore.Defaults.agentsNeedsYouBypassQuietHours
        s.agentsNotifyDone = !SettingsStore.Defaults.agentsNotifyDone
        s.agentsShowInMenuBar = !SettingsStore.Defaults.agentsShowInMenuBar
        s.agentsAnswerPermissions = !SettingsStore.Defaults.agentsAnswerPermissions
        s.agentsHooksPromptDismissed = !SettingsStore.Defaults.agentsHooksPromptDismissed
        s.agentsHooksPromptNotified = !SettingsStore.Defaults.agentsHooksPromptNotified

        // Preferences that live outside this object but are still preferences. Written
        // by key rather than through the state objects, so the scramble doesn't kick off
        // a dashboard reload against the developer's real history log.
        UserDefaults.standard.set("codex", forKey: DashboardState.selectionKey)
        UserDefaults.standard.set("grok", forKey: "selectedProviderTab")
        UserDefaults.standard.set(["claude:five_hour": 95], forKey: UsageNotifier.firedLevelsKey)
        UserDefaults.standard.set(
            ["reset:claude:five_hour": Date().timeIntervalSince1970],
            forKey: UsageNotifier.firedWindowsKey
        )
    }

    @MainActor
    private func assertAllDefaults(_ s: SettingsStore, _ message: String = "") {
        XCTAssertEqual(s.refreshIntervalSeconds, SettingsStore.Defaults.refreshIntervalSeconds, message)
        XCTAssertEqual(s.anthropicBetaHeader, SettingsStore.Defaults.anthropicBetaHeader, message)
        XCTAssertEqual(s.preferAdminWhenAvailable, SettingsStore.Defaults.preferAdminWhenAvailable, message)
        XCTAssertEqual(s.codexProviderEnabled, SettingsStore.Defaults.codexProviderEnabled, message)
        XCTAssertEqual(s.geminiProviderEnabled, SettingsStore.Defaults.geminiProviderEnabled, message)
        XCTAssertEqual(s.antigravityProviderEnabled, SettingsStore.Defaults.antigravityProviderEnabled, message)
        XCTAssertEqual(s.grokProviderEnabled, SettingsStore.Defaults.grokProviderEnabled, message)
        XCTAssertEqual(s.claudeWeeklyBudgetUSD, SettingsStore.Defaults.claudeWeeklyBudgetUSD, message)
        XCTAssertEqual(s.notificationsEnabled, SettingsStore.Defaults.notificationsEnabled, message)
        XCTAssertEqual(s.threshold80, SettingsStore.Defaults.threshold80, message)
        XCTAssertEqual(s.threshold95, SettingsStore.Defaults.threshold95, message)
        XCTAssertEqual(s.paceAlertsEnabled, SettingsStore.Defaults.paceAlertsEnabled, message)
        XCTAssertEqual(s.paceAlertLeadMinutes, SettingsStore.Defaults.paceAlertLeadMinutes, message)
        XCTAssertEqual(s.resetAlertsEnabled, SettingsStore.Defaults.resetAlertsEnabled, message)
        XCTAssertEqual(s.quietHoursEnabled, SettingsStore.Defaults.quietHoursEnabled, message)
        XCTAssertEqual(s.quietHoursStart, SettingsStore.Defaults.quietHoursStart, message)
        XCTAssertEqual(s.quietHoursEnd, SettingsStore.Defaults.quietHoursEnd, message)
        XCTAssertEqual(s.dailySummaryEnabled, SettingsStore.Defaults.dailySummaryEnabled, message)
        XCTAssertEqual(s.dailySummaryHour, SettingsStore.Defaults.dailySummaryHour, message)
        XCTAssertEqual(s.lastDailySummaryDay, SettingsStore.Defaults.lastDailySummaryDay, message)
        XCTAssertEqual(s.menuBarHiddenServicesRaw, SettingsStore.Defaults.menuBarHiddenServicesRaw, message)
        XCTAssertEqual(s.menuBarNumberMode, SettingsStore.Defaults.menuBarNumberMode, message)
        XCTAssertEqual(s.hasSeenOnboarding, SettingsStore.Defaults.hasSeenOnboarding, message)
        XCTAssertEqual(s.agentsNotifyNeedsYou, SettingsStore.Defaults.agentsNotifyNeedsYou, message)
        XCTAssertEqual(s.agentsNeedsYouBypassQuietHours, SettingsStore.Defaults.agentsNeedsYouBypassQuietHours, message)
        XCTAssertEqual(s.agentsNotifyDone, SettingsStore.Defaults.agentsNotifyDone, message)
        XCTAssertEqual(s.agentsShowInMenuBar, SettingsStore.Defaults.agentsShowInMenuBar, message)
        XCTAssertEqual(s.agentsAnswerPermissions, SettingsStore.Defaults.agentsAnswerPermissions, message)
        XCTAssertEqual(s.agentsHooksPromptDismissed, SettingsStore.Defaults.agentsHooksPromptDismissed, message)
        XCTAssertEqual(s.agentsHooksPromptNotified, SettingsStore.Defaults.agentsHooksPromptNotified, message)

        XCTAssertEqual(DashboardState.shared.selectedService, DashboardState.defaultService, message)
        XCTAssertNil(UserDefaults.standard.string(forKey: "selectedProviderTab"), message)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: UsageNotifier.firedLevelsKey), message)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: UsageNotifier.firedWindowsKey), message)
    }

    @MainActor
    func testResetPutsEverySettingBackToItsDefault() {
        let settings = SettingsStore.shared
        scrambleEverything(settings)

        // Sanity: the scramble really did move things, so the assertions below mean something.
        XCTAssertNotEqual(settings.refreshIntervalSeconds, SettingsStore.Defaults.refreshIntervalSeconds)
        XCTAssertNotEqual(settings.menuBarNumberMode, SettingsStore.Defaults.menuBarNumberMode)
        XCTAssertNotEqual(settings.hasSeenOnboarding, SettingsStore.Defaults.hasSeenOnboarding)
        XCTAssertEqual(UserDefaults.standard.string(forKey: DashboardState.selectionKey), "codex")

        settings.resetToDefaults()

        assertAllDefaults(settings, "a setting survived resetToDefaults()")
    }

    /// The five the reset used to walk straight past. They aren't `@AppStorage`
    /// properties on this object, which is exactly why they were missed.
    @MainActor
    func testResetAlsoForgetsTheChoicesStoredOutsideThisObject() {
        let settings = SettingsStore.shared
        scrambleEverything(settings)

        settings.resetToDefaults()

        XCTAssertEqual(
            DashboardState.shared.selectedService, "claude",
            "the dashboard stayed on whichever provider was picked"
        )
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "selectedProviderTab"),
            "the popover stayed on whichever tab was picked"
        )
        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: UsageNotifier.firedLevelsKey),
            "'already alerted at 95%' outlived the thresholds that produced it"
        )
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: UsageNotifier.firedWindowsKey))
    }

    @MainActor
    func testResetForgetsTheOnboardingAndTheMenuBarChoices() {
        // The four the old button silently skipped.
        let settings = SettingsStore.shared
        settings.hasSeenOnboarding = true
        settings.menuBarHiddenServicesRaw = "codex"
        settings.claudeWeeklyBudgetUSD = 99
        settings.paceAlertLeadMinutes = 15

        settings.resetToDefaults()

        XCTAssertFalse(settings.hasSeenOnboarding)
        XCTAssertEqual(settings.menuBarHiddenServices, [])
        XCTAssertEqual(settings.claudeWeeklyBudgetUSD, 0)
        XCTAssertEqual(settings.paceAlertLeadMinutes, 45)
    }

    @MainActor
    func testMenuBarVisibilityRoundTripsThroughTheStoredString() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()

        XCTAssertTrue(settings.isShownInMenuBar("codex"))
        settings.setShownInMenuBar("codex", false)
        XCTAssertFalse(settings.isShownInMenuBar("codex"))
        XCTAssertTrue(settings.isShownInMenuBar("claude"))
        settings.setShownInMenuBar("codex", true)
        XCTAssertTrue(settings.isShownInMenuBar("codex"))
        XCTAssertEqual(settings.menuBarHiddenServicesRaw, "")
    }

    @MainActor
    func testTheAgentDefaultsAreTheOnesTheAgentsTabPromises() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()

        XCTAssertTrue(settings.agentsNotifyNeedsYou)
        XCTAssertTrue(settings.agentsNeedsYouBypassQuietHours, "a session waiting for approval is the one alert worth waking you")
        XCTAssertFalse(settings.agentsNotifyDone, "a notification per finished turn would be noise")
        XCTAssertTrue(settings.agentsShowInMenuBar)
        XCTAssertTrue(
            settings.agentsAnswerPermissions,
            "the presence rule is what makes this safe to default on: a request is only held when the terminal isn't in front"
        )
    }

    /// The hooks prompt is one-time in both directions: "Not now" is final, and a
    /// settings reset is the only way back to it.
    @MainActor
    func testResettingSettingsOffersTheHooksPromptAgain() {
        let settings = SettingsStore.shared
        settings.agentsHooksPromptDismissed = true
        settings.agentsHooksPromptNotified = true

        settings.resetToDefaults()

        XCTAssertFalse(settings.agentsHooksPromptDismissed)
        XCTAssertFalse(settings.agentsHooksPromptNotified, "the launch notification may speak once more")
    }
}
