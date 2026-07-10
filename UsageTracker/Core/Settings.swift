import Foundation
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

    @AppStorage("refreshIntervalSeconds") var refreshIntervalSeconds: Int = 60
    @AppStorage("autoLaunch") var autoLaunch: Bool = false
    @AppStorage("anthropicBetaHeader") var anthropicBetaHeader: String = "oauth-2025-04-20"
    @AppStorage("preferAdminWhenAvailable") var preferAdminWhenAvailable: Bool = false
    // Defaults to on when the Codex CLI has been signed into on this machine.
    @AppStorage("codexProviderEnabled") var codexProviderEnabled: Bool = CodexProvider.isCodexInstalled
    // Defaults to on once the Gemini CLI has OAuth credentials on this machine.
    @AppStorage("geminiProviderEnabled") var geminiProviderEnabled: Bool = GeminiProvider.isGeminiSignedIn
    // Defaults to on when Antigravity (app or CLI) is installed on this machine.
    @AppStorage("antigravityProviderEnabled") var antigravityProviderEnabled: Bool = AntigravityProvider.isAntigravityInstalled
    // Pay-as-you-go accounts: weekly $ budget the local CLI spend is measured
    // against (0 = no budget set). Only used when the account has no rate windows.
    @AppStorage("claudeWeeklyBudgetUSD") var claudeWeeklyBudgetUSD: Double = 0
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("threshold80") var threshold80: Int = 80
    @AppStorage("threshold95") var threshold95: Int = 95
    @AppStorage("quietHoursEnabled") var quietHoursEnabled: Bool = true
    @AppStorage("quietHoursStart") var quietHoursStart: Int = 23   // 23:00
    @AppStorage("quietHoursEnd") var quietHoursEnd: Int = 9        // 09:00
    @AppStorage("dailySummaryEnabled") var dailySummaryEnabled: Bool = true
    @AppStorage("dailySummaryHour") var dailySummaryHour: Int = 9  // 09:00 local
    @AppStorage("lastDailySummaryDay") var lastDailySummaryDay: String = ""
    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = false

    private init() {}

    var interval: TimeInterval {
        TimeInterval(refreshIntervalSeconds)
    }
}
