import Foundation

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
        static let showsRemaining = false
        static let hasSeenOnboarding = false
        static let hasOpenedIslandAfterUpdate = false
        static let agentsNotifyNeedsYou = true
        static let agentsNeedsYouBypassQuietHours = true
        static let agentsNotifyDone = false
        static let agentsShowInMenuBar = true
        static let agentsAnswerPermissions = true
        static let agentsHooksPromptDismissed = false
        static let agentsHooksPromptNotified = false
        /// Keep awake ends by itself on battery below 25 % (spec 2026-10-26, Battery floor).
        static let keepAwakeFloorEnabled = true
        /// The last duration Apply used, in minutes; one hour until the first Apply.
        static let keepAwakeDurationMinutes = 60
        /// Show in menu bar: nothing stored, so the default follows the displays
        /// (notch-island spec 2026-10-29 § 3.7, `StatusItemVisibilityRules`).
        static let showInMenuBar: Bool? = nil
        /// Island on displays without a notch (spec 2026-11-03 § P4): on, 4.1's virtual notch.
        static let virtualNotchEnabled = true
        /// Settings › Pet (notch-island spec 2026-10-29 § 3.7): on, on, the cat in ginger.
        static let petEnabled = true
        static let earsEnabled = true
        static let petChoice = PetChoice.standard

        // Provider toggles are auto-detection, not fixed values: a reset should
        // re-detect what's installed now rather than pin what was found at first
        // launch. `@AppStorage` keeps re-evaluating these until the user decides.
        static var claudeProviderEnabled: Bool { ClaudeOAuthProvider.isClaudeInstalled }
        static var codexProviderEnabled: Bool { CodexProvider.isCodexInstalled }
        static var antigravityProviderEnabled: Bool { AntigravityProvider.isAntigravityInstalled }
        static var grokProviderEnabled: Bool { GrokProvider.isGrokInstalled }
    }

    @AppStorage("refreshIntervalSeconds") var refreshIntervalSeconds: Int = Defaults.refreshIntervalSeconds
    // No `autoLaunch` key: launch at login is `SMAppService` state, and the Settings
    // toggle has always read and written `LaunchAtLogin.isEnabled`. The stored
    // preference was written by nothing and read by nothing but its own reset.
    @AppStorage("anthropicBetaHeader") var anthropicBetaHeader: String = Defaults.anthropicBetaHeader
    @AppStorage("preferAdminWhenAvailable") var preferAdminWhenAvailable: Bool = Defaults.preferAdminWhenAvailable
    // Defaults to on wherever Claude has been seen on this Mac: ~/.claude, the Claude app,
    // or a kept Claude reading (spec 2026-10-25 § Package 1).
    @AppStorage("claudeProviderEnabled") var claudeProviderEnabled: Bool = Defaults.claudeProviderEnabled
    // Defaults to on when the Codex CLI has been signed into on this machine.
    @AppStorage("codexProviderEnabled") var codexProviderEnabled: Bool = Defaults.codexProviderEnabled
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

    /// Defaults key for the display mode. Spelled out because it is read by name in
    /// the tests, and because the property below is not `@AppStorage`.
    static let showsRemainingKey = "showsRemaining"

    /// "Show remaining instead of used": every ring, bar and number counts down from
    /// 100 instead of up from 0.
    ///
    /// Deliberately not `@AppStorage` like its neighbours. `@AppStorage` is a
    /// `DynamicProperty`: inside an `ObservableObject` it reads and writes
    /// `UserDefaults` correctly but never sends `objectWillChange`, so nothing that
    /// observes this store is invalidated when it moves. Every other preference here
    /// can live with that — they gate a poll, a notification or a pill that redraws
    /// on the next snapshot. This one has to repaint every ring in the app the
    /// instant the switch moves, so it is a plain `@Published` over an explicit
    /// read and write of the same key.
    @Published var showsRemaining: Bool = Defaults.showsRemaining {
        didSet {
            guard oldValue != showsRemaining else { return }
            UserDefaults.standard.set(showsRemaining, forKey: Self.showsRemainingKey)
        }
    }

    /// What every surface asks for. One computed property rather than each view
    /// spelling out the ternary, so "off means used" is decided once.
    var percentMode: PercentDisplay.Mode { showsRemaining ? .remaining : .used }

    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = Defaults.hasSeenOnboarding

    /// The one time a launch opened the island in place of a status item that went away with
    /// 4.0, or found it had no need to (`StatusItemVisibilityRules.firstLaunchAfterUpdate`).
    @AppStorage("hasOpenedIslandAfterUpdate") var hasOpenedIslandAfterUpdate: Bool = Defaults.hasOpenedIslandAfterUpdate

    /// A session stopped and is waiting for a permission decision.
    @AppStorage("agentsNotifyNeedsYou") var agentsNotifyNeedsYou: Bool = Defaults.agentsNotifyNeedsYou
    /// "Needs you" is the one alert worth waking someone: on by default it ignores
    /// quiet hours, because an agent that waits all night has wasted the night.
    @AppStorage("agentsNeedsYouBypassQuietHours") var agentsNeedsYouBypassQuietHours: Bool = Defaults.agentsNeedsYouBypassQuietHours
    /// A session finished its turn. Off by default — it fires on every reply.
    @AppStorage("agentsNotifyDone") var agentsNotifyDone: Bool = Defaults.agentsNotifyDone
    /// The agents pill in the menu bar (count of live sessions).
    @AppStorage("agentsShowInMenuBar") var agentsShowInMenuBar: Bool = Defaults.agentsShowInMenuBar
    /// Phase 4: hold a Claude Code permission request and offer Allow / Deny from
    /// Omelette while the hosting terminal is not in front. Read by `PermissionBroker`.
    @AppStorage("agentsAnswerPermissions") var agentsAnswerPermissions: Bool = Defaults.agentsAnswerPermissions
    /// "Not now" on the one-time hooks prompt. Hooks stay opt-in, so the answer
    /// is remembered and the row never asks again — a settings reset is the way back.
    @AppStorage("agentsHooksPromptDismissed") var agentsHooksPromptDismissed: Bool = Defaults.agentsHooksPromptDismissed
    /// The launch notification for that prompt has been delivered. One per install,
    /// ever — separate from the row, which the popover can show until it is answered.
    @AppStorage("agentsHooksPromptNotified") var agentsHooksPromptNotified: Bool = Defaults.agentsHooksPromptNotified
    /// Read at every Apply, and sent to an armed helper the moment it changes
    /// (`KeepAwakeModel.floorChanged`).
    @AppStorage("keepAwakeFloorEnabled") var keepAwakeFloorEnabled: Bool = Defaults.keepAwakeFloorEnabled
    /// The last duration Apply used, in minutes; the popover's fields start from
    /// `KeepAwakeRules.parts(totalMinutes:)` of it.
    @AppStorage("keepAwakeDurationMinutes") var keepAwakeDurationMinutes: Int = Defaults.keepAwakeDurationMinutes

    /// Defaults key for Show in menu bar. Spelled out because the tests read it by name.
    static let showInMenuBarKey = "showInMenuBar"

    /// Show in menu bar (notch-island spec 2026-10-29 § 3.7, D4; spec 2026-11-03 § Status
    /// item): nil until the user flips the switch, so the default can follow the displays —
    /// off while a display shows the island (a notch, or the pill on a display without one). A plain `@Published` over an explicit read and write of the key, for the
    /// reason `showsRemaining` gives: the status item hides and shows the moment it moves.
    @Published var showInMenuBar: Bool? = Defaults.showInMenuBar {
        didSet {
            guard oldValue != showInMenuBar else { return }
            if let showInMenuBar {
                UserDefaults.standard.set(showInMenuBar, forKey: Self.showInMenuBarKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.showInMenuBarKey)
            }
        }
    }

    /// Defaults key for Island on displays without a notch. Spelled out because the tests read it by name.
    static let virtualNotchEnabledKey = "virtualNotchEnabled"

    /// Island on displays without a notch (spec 2026-11-03 § P4): on, a display without a camera
    /// housing gets the virtual notch; off, 4.0's menu bar icon and its panel there. Every reading of
    /// the displays carries it (`IslandScreen.current()`). A plain `@Published` over an explicit key for
    /// the reason `showsRemaining` gives: the pills, the ears and the status item follow at once.
    @Published var virtualNotchEnabled: Bool = Defaults.virtualNotchEnabled {
        didSet {
            guard oldValue != virtualNotchEnabled else { return }
            UserDefaults.standard.set(virtualNotchEnabled, forKey: Self.virtualNotchEnabledKey)
        }
    }

    /// Defaults keys for Settings › Pet. Spelled out because the tests read them by name.
    static let petEnabledKey = "petEnabled"
    static let earsEnabledKey = "earsEnabled"
    static let petAnimalKey = "petAnimal"
    static let petPaletteKey = "petPalette"

    /// The pet on the island (§ 3.7, D12). A plain `@Published` over an explicit key for the reason
    /// `showsRemaining` gives: the island's layout and the ears follow at once.
    @Published var petEnabled: Bool = Defaults.petEnabled {
        didSet {
            guard oldValue != petEnabled else { return }
            UserDefaults.standard.set(petEnabled, forKey: Self.petEnabledKey)
        }
    }

    /// The ears beside the notch (§ 3.6, § 3.7).
    @Published var earsEnabled: Bool = Defaults.earsEnabled {
        didSet {
            guard oldValue != earsEnabled else { return }
            UserDefaults.standard.set(earsEnabled, forKey: Self.earsEnabledKey)
        }
    }

    /// The animal and palette as chosen, one value so a picker click is one change. It may be stale:
    /// everything that draws goes through `PetChoiceRules.resolved`.
    @Published var petChoice: PetChoice = Defaults.petChoice {
        didSet {
            guard oldValue != petChoice else { return }
            UserDefaults.standard.set(petChoice.animal, forKey: Self.petAnimalKey)
            UserDefaults.standard.set(petChoice.palette, forKey: Self.petPaletteKey)
        }
    }

    /// What the defaults hold as a choice: nothing is the standard pet; an animal with no palette
    /// is that animal, its palette resolved when it is drawn.
    nonisolated static func storedPetChoice(animal: String?, palette: String?) -> PetChoice {
        guard let animal else { return PetChoice.standard }
        return PetChoice(animal: animal, palette: palette ?? "")
    }

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
        claudeProviderEnabled = Defaults.claudeProviderEnabled
        codexProviderEnabled = Defaults.codexProviderEnabled
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
        showsRemaining = Defaults.showsRemaining
        hasSeenOnboarding = Defaults.hasSeenOnboarding
        hasOpenedIslandAfterUpdate = Defaults.hasOpenedIslandAfterUpdate
        agentsNotifyNeedsYou = Defaults.agentsNotifyNeedsYou
        agentsNeedsYouBypassQuietHours = Defaults.agentsNeedsYouBypassQuietHours
        agentsNotifyDone = Defaults.agentsNotifyDone
        agentsShowInMenuBar = Defaults.agentsShowInMenuBar
        agentsAnswerPermissions = Defaults.agentsAnswerPermissions
        agentsHooksPromptDismissed = Defaults.agentsHooksPromptDismissed
        agentsHooksPromptNotified = Defaults.agentsHooksPromptNotified
        showInMenuBar = Defaults.showInMenuBar
        // The `didSet` above skips an unchanged nil, and the key can hold a value this object
        // never saw (a restored domain, another copy of the app): remove it either way.
        UserDefaults.standard.removeObject(forKey: Self.showInMenuBarKey)
        virtualNotchEnabled = Defaults.virtualNotchEnabled
        UserDefaults.standard.removeObject(forKey: Self.virtualNotchEnabledKey)
        petEnabled = Defaults.petEnabled
        earsEnabled = Defaults.earsEnabled
        petChoice = Defaults.petChoice
        // As with Show in menu bar: a key can hold what this object never saw.
        for key in [Self.petEnabledKey, Self.earsEnabledKey, Self.petAnimalKey, Self.petPaletteKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        resetKeepAwake()

        // Choices that live in the views and state objects rather than in a property
        // here. They are still preferences, so a reset that leaves them behind isn't
        // one: the dashboard stayed on whichever provider was picked, the popover on
        // whichever tab.
        DashboardState.shared.resetSelection()
        UserDefaults.standard.removeObject(forKey: Self.popoverTabKey)
        // The Limits tab's window switch, and its Chats / Projects choice per provider.
        UserDefaults.standard.removeObject(forKey: LimitsRules.windowKey)
        UserDefaults.standard.removeObject(forKey: LimitsRules.groupingKey)
        // What 3.x kept of the popover's heights per tab; 4.0 writes nothing there.
        UserDefaults.standard.removeObject(forKey: PopoverHeightRules.fixedHeightsKey)
        // "Already alerted at 80%" is state the old thresholds produced; after a reset
        // the new ones should be able to speak.
        UsageNotifier.shared.forgetFiredState()
    }

    /// Settings › Advanced › Reset keep awake puts these two back, and nothing else.
    func resetKeepAwake() {
        keepAwakeFloorEnabled = Defaults.keepAwakeFloorEnabled
        keepAwakeDurationMinutes = Defaults.keepAwakeDurationMinutes
    }

    /// The tab the 3.x popover (and 4.0 before its navigation) remembered. The island keeps no
    /// page between opens (notch-island spec § 3.4), so nothing reads or writes it now; Reset
    /// still removes the copy an older build left.
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

    private init() {
        // Property observers do not fire from an initializer, which is exactly what
        // is wanted here: reading the stored value must not write it back.
        showsRemaining = UserDefaults.standard.bool(forKey: Self.showsRemainingKey)
        showInMenuBar = UserDefaults.standard.object(forKey: Self.showInMenuBarKey) as? Bool
        virtualNotchEnabled = UserDefaults.standard.object(forKey: Self.virtualNotchEnabledKey) as? Bool
            ?? Defaults.virtualNotchEnabled
        petEnabled = UserDefaults.standard.object(forKey: Self.petEnabledKey) as? Bool ?? Defaults.petEnabled
        earsEnabled = UserDefaults.standard.object(forKey: Self.earsEnabledKey) as? Bool ?? Defaults.earsEnabled
        petChoice = Self.storedPetChoice(
            animal: UserDefaults.standard.string(forKey: Self.petAnimalKey),
            palette: UserDefaults.standard.string(forKey: Self.petPaletteKey)
        )
    }

    var interval: TimeInterval {
        TimeInterval(refreshIntervalSeconds)
    }
}
