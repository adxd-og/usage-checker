import Foundation

/// Which Settings tab the next `openSettings()` should land on.
///
/// SwiftUI's `Settings` scene exposes no tab selection, and `SettingsView` keeps
/// its selection in `@State`, so a caller parks the request here and the window
/// picks it up when it appears (or immediately, if it is already open). The
/// value is deliberately not persisted: it is a navigation intent, not a setting.
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()

    /// 2.x's Agents tab. Its hooks now live on Integrations, where
    /// `SettingsTab.route(legacyID:)` sends this id; a 3.0 tab's own name
    /// (`SettingsTab.rawValue`) lands on that tab, and any other name on General.
    static let agentsTab = "Agents"

    @Published var pendingTab: String?

    /// Reads and clears in one step — a tab request must never fire twice.
    func consumePendingTab() -> String? {
        defer { pendingTab = nil }
        return pendingTab
    }
}
