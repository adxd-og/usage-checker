import SwiftUI
import AppKit

/// The Settings window (liquid-glass spec § Design → Settings): 780 pt wide, as tall as
/// the selected tab's mockup, the dashboard's floating glass sidebar with six tabs, and
/// the tab's page beside it. Every row is a 2.x setting, regrouped; the pages live in
/// `UsageTracker/UI/Settings/`.
struct SettingsView: View {
    @ObservedObject private var route = SettingsRoute.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedTab)
                .padding([.top, .bottom, .leading], SettingsWindowLayout.windowInset)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding([.top, .bottom, .trailing], SettingsWindowLayout.windowInset)
        }
        // The sidebar reaches up under the traffic lights, as the dashboard's does: the
        // scene hides the title bar (`UsageTrackerApp`) and the window draws its own chrome.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            ZStack {
                OMWindowBackground()
                // The window's body over the backdrop, as on the dashboard.
                Rectangle()
                    .fill(.om(.windowTint))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .frame(
            width: SettingsWindowLayout.width,
            height: SettingsWindowLayout.height(
                for: selectedTab, availableHeight: NSScreen.main?.visibleFrame.height
            )
        )
        // Backs up the scene's hidden title bar: no title text, no toolbar band.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The traffic lights inside the sidebar panel, as the mockups draw them.
        .background(WindowButtonsPlacement())
        .onAppear(perform: applyPendingTab)
        // The window may already be open when the popover asks for a tab, in which case
        // onAppear has long since fired.
        .onChange(of: route.pendingTab) { _, _ in applyPendingTab() }
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .general: GeneralSettingsView()
        case .menuBar: MenuBarSettingsView()
        case .providers: ProvidersSettingsView()
        case .notifications: NotificationsSettingsView()
        case .integrations: IntegrationsSettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }

    /// A tab parked by the popover or the hooks banner. 2.x's ids still land
    /// (`SettingsTab.route(legacyID:)`: Agents → Integrations, Account → Providers).
    private func applyPendingTab() {
        guard let id = route.consumePendingTab() else { return }
        selectedTab = SettingsTab.route(legacyID: id)
    }

    /// What a service reported, in the words the rest of the app uses: the two windows
    /// closest to their limit, or the pay-as-you-go spend, or a dash when it has reported
    /// nothing. 2.x's Account tab showed it beside each provider; 3.0's Providers row shows
    /// the plan instead. It stays because the remaining-mode tests pin its ranking.
    ///
    /// Which two windows is a question about usage and never changes; what they print is
    /// the user's choice.
    nonisolated static func usageSummary(_ svc: ServiceSnapshot, mode: PercentDisplay.Mode) -> String {
        let worst = svc.buckets
            .filter { !$0.isPromotional }
            .sorted { $0.clampedPercent > $1.clampedPercent }
            .prefix(2)
        if !worst.isEmpty {
            return worst
                .map { "\(shortWindowName($0)) \(PercentDisplay.percentText($0.clampedPercent, mode: mode))" }
                .joined(separator: " · ")
        }
        if let extra = svc.extraUsage, extra.isEnabled, extra.monthlyLimit > 0 {
            return String(format: "$%.2f of $%.2f", extra.usedCredits, extra.monthlyLimit)
        }
        if let cost = svc.weekCost, cost > 0 {
            return String(format: "$%.2f this week", cost)
        }
        return "—"
    }

    nonisolated static func shortWindowName(_ b: UsageBucket) -> String {
        switch b.kind {
        case .session: return "Session"
        case .weekly: return "Week"
        case .modelSpecific, .other: return b.label
        }
    }
}

extension Notification.Name {
    static let replayOnboarding = Notification.Name("com.usagetracker.replayOnboarding")
}

#if DEBUG
// The window reads the real stores, which is the point: this preview is how the tabs get
// checked in both schemes. Advanced reads the keychain on appear (the masked admin key),
// so macOS may show one access dialog the first time.
#Preview("Settings — light") {
    SettingsView()
}

#Preview("Settings — dark") {
    SettingsView()
        .preferredColorScheme(.dark)
}
#endif
