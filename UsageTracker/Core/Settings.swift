import Foundation
import KeyboardShortcuts

/// When the menu bar shows a percentage next to the bar.
enum MenuBarNumberMode: String, CaseIterable, Identifiable, Sendable {
    /// Only when a single provider is on show — several numbers turn the menu bar into a ruler.
    case auto
    case always
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Only for a single provider"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}
import SwiftUI

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case s30 = 30
    case m1 = 60
    case m5 = 300

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .s30: return "30 seconds"
        case .m1: return "1 minute"
        case .m5: return "5 minutes"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// The one place every default lives. Both the `@AppStorage` wrappers below and
    /// `resetToDefaults()` read from here — a second hardcoded copy is exactly what
    /// drifts apart the moment a setting is added.
    enum Defaults {
        static let refreshIntervalSeconds = 60
        static let anthropicBetaHeader = "oauth-2025-04-20"
        static let preferAdminWhenAvailable = false
        static let claudeWeeklyBudgetUSD: Double = 0
        static let notificationsEnabled = true
        static let threshold80 = 80
        static let threshold95 = 95
        static let paceAlertsEnabled = true
        static let paceAlertLeadMinutes = 45
        static let resetAlertsEnabled = true
        static let quietHoursEnabled = true
        static let quietHoursStart = 23   // 23:00
        static let quietHoursEnd = 9      // 09:00
        static let dailySummaryEnabled = true
        static let dailySummaryHour = 9   // 09:00 local
        static let lastDailySummaryDay = ""
        static let menuBarHiddenServicesRaw = ""
        static let menuBarNumberMode = MenuBarNumberMode.auto
        static let hasSeenOnboarding = false

        // Provider toggles are auto-detection, not fixed values: a reset should
        // re-detect what's installed now rather than pin what was found at first
        // launch. `@AppStorage` keeps re-evaluating these until the user decides.
        static var codexProviderEnabled: Bool { CodexProvider.isCodexInstalled }
        static var geminiProviderEnabled: Bool { GeminiProvider.isGeminiSignedIn }
        static var antigravityProviderEnabled: Bool { AntigravityProvider.isAntigravityInstalled }
        static var grokProviderEnabled: Bool { GrokProvider.isGrokInstalled }
    }

    @AppStorage("refreshIntervalSeconds") var refreshIntervalSeconds: Int = Defaults.refreshIntervalSeconds
    // No `autoLaunch` key: launch at login is `SMAppService` state, and the Settings
    // toggle has always read and written `LaunchAtLogin.isEnabled`. The stored
    // preference was written by nothing and read by nothing but its own reset.
    @AppStorage("anthropicBetaHeader") var anthropicBetaHeader: String = Defaults.anthropicBetaHeader
    @AppStorage("preferAdminWhenAvailable") var preferAdminWhenAvailable: Bool = Defaults.preferAdminWhenAvailable
    // Defaults to on when the Codex CLI has been signed into on this machine.
    @AppStorage("codexProviderEnabled") var codexProviderEnabled: Bool = Defaults.codexProviderEnabled
    // Defaults to on once the Gemini CLI has OAuth credentials on this machine.
    @AppStorage("geminiProviderEnabled") var geminiProviderEnabled: Bool = Defaults.geminiProviderEnabled
    // Defaults to on when Antigravity (app or CLI) is installed on this machine.
    @AppStorage("antigravityProviderEnabled") var antigravityProviderEnabled: Bool = Defaults.antigravityProviderEnabled
    // Defaults to on once the Grok CLI has been signed into on this machine.
    @AppStorage("grokProviderEnabled") var grokProviderEnabled: Bool = Defaults.grokProviderEnabled
    // Pay-as-you-go accounts: weekly $ budget the local CLI spend is measured
    // against (0 = no budget set). Only used when the account has no rate windows.
    @AppStorage("claudeWeeklyBudgetUSD") var claudeWeeklyBudgetUSD: Double = Defaults.claudeWeeklyBudgetUSD
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = Defaults.notificationsEnabled
    @AppStorage("threshold80") var threshold80: Int = Defaults.threshold80
    @AppStorage("threshold95") var threshold95: Int = Defaults.threshold95
    /// "At this pace you'll run out before the window resets."
    @AppStorage("paceAlertsEnabled") var paceAlertsEnabled: Bool = Defaults.paceAlertsEnabled
    /// How far ahead the pace alert warns, in minutes.
    @AppStorage("paceAlertLeadMinutes") var paceAlertLeadMinutes: Int = Defaults.paceAlertLeadMinutes
    /// "The window you're squeezed against resets in a few minutes."
    @AppStorage("resetAlertsEnabled") var resetAlertsEnabled: Bool = Defaults.resetAlertsEnabled
    @AppStorage("quietHoursEnabled") var quietHoursEnabled: Bool = Defaults.quietHoursEnabled
    @AppStorage("quietHoursStart") var quietHoursStart: Int = Defaults.quietHoursStart
    @AppStorage("quietHoursEnd") var quietHoursEnd: Int = Defaults.quietHoursEnd
    @AppStorage("dailySummaryEnabled") var dailySummaryEnabled: Bool = Defaults.dailySummaryEnabled
    @AppStorage("dailySummaryHour") var dailySummaryHour: Int = Defaults.dailySummaryHour
    @AppStorage("lastDailySummaryDay") var lastDailySummaryDay: String = Defaults.lastDailySummaryDay
    /// Service ids kept out of the menu bar, comma-separated. They stay in the popover,
    /// the widget and notifications — this is purely about menu bar real estate.
    @AppStorage("menuBarHiddenServices") var menuBarHiddenServicesRaw: String = Defaults.menuBarHiddenServicesRaw
    @AppStorage("menuBarNumberMode") var menuBarNumberMode: MenuBarNumberMode = Defaults.menuBarNumberMode

    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = Defaults.hasSeenOnboarding

    /// Puts every stored setting back to its default. Lives here rather than in the
    /// Settings button so adding a setting means touching one file, not two — the
    /// old button reset ten of them and quietly left providers, budget, menu bar
    /// options, pace/reset alerts and onboarding as they were.
    ///
    /// Launch at login is the one exception and stays with the caller: it is OS state
    /// (`SMAppService`), not a preference, and unregistering a login item from here
    /// would fire from the test suite as well.
    func resetToDefaults() {
        refreshIntervalSeconds = Defaults.refreshIntervalSeconds
        anthropicBetaHeader = Defaults.anthropicBetaHeader
        preferAdminWhenAvailable = Defaults.preferAdminWhenAvailable
        codexProviderEnabled = Defaults.codexProviderEnabled
        geminiProviderEnabled = Defaults.geminiProviderEnabled
        antigravityProviderEnabled = Defaults.antigravityProviderEnabled
        grokProviderEnabled = Defaults.grokProviderEnabled
        claudeWeeklyBudgetUSD = Defaults.claudeWeeklyBudgetUSD
        notificationsEnabled = Defaults.notificationsEnabled
        threshold80 = Defaults.threshold80
        threshold95 = Defaults.threshold95
        paceAlertsEnabled = Defaults.paceAlertsEnabled
        paceAlertLeadMinutes = Defaults.paceAlertLeadMinutes
        resetAlertsEnabled = Defaults.resetAlertsEnabled
        quietHoursEnabled = Defaults.quietHoursEnabled
        quietHoursStart = Defaults.quietHoursStart
        quietHoursEnd = Defaults.quietHoursEnd
        dailySummaryEnabled = Defaults.dailySummaryEnabled
        dailySummaryHour = Defaults.dailySummaryHour
        lastDailySummaryDay = Defaults.lastDailySummaryDay
        menuBarHiddenServicesRaw = Defaults.menuBarHiddenServicesRaw
        menuBarNumberMode = Defaults.menuBarNumberMode
        hasSeenOnboarding = Defaults.hasSeenOnboarding

        // Choices that live in the views and state objects rather than in a property
        // here. They are still preferences, so a reset that leaves them behind isn't
        // one: the dashboard stayed on whichever provider was picked, the popover on
        // whichever tab, and the recorded hotkey kept firing.
        DashboardState.shared.resetSelection()
        UserDefaults.standard.removeObject(forKey: Self.popoverTabKey)
        KeyboardShortcuts.reset(.peekUsage)
        // "Already alerted at 80%" is state the old thresholds produced; after a reset
        // the new ones should be able to speak.
        UsageNotifier.shared.forgetFiredState()
    }

    /// PopoverView's persisted tab. Owned by the view, reset here.
    private static let popoverTabKey = "selectedProviderTab"

    var menuBarHiddenServices: Set<String> {
        get { Set(menuBarHiddenServicesRaw.split(separator: ",").map(String.init)) }
        set { menuBarHiddenServicesRaw = newValue.sorted().joined(separator: ",") }
    }

    func isShownInMenuBar(_ serviceID: String) -> Bool {
        !menuBarHiddenServices.contains(serviceID)
    }

    func setShownInMenuBar(_ serviceID: String, _ shown: Bool) {
        var hidden = menuBarHiddenServices
        if shown { hidden.remove(serviceID) } else { hidden.insert(serviceID) }
        menuBarHiddenServices = hidden
    }

    private init() {}

    var interval: TimeInterval {
        TimeInterval(refreshIntervalSeconds)
    }
}
