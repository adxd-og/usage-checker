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

    /// Matches `SettingsView.Tab.rawValue`. A name with no matching tab is
    /// ignored, so a request can outlive a tab being renamed or not existing yet.
    static let agentsTab = "Agents"

    @Published var pendingTab: String?

    /// Reads and clears in one step — a tab request must never fire twice.
    func consumePendingTab() -> String? {
        defer { pendingTab = nil }
        return pendingTab
    }
}
