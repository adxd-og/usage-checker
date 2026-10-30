/// What a reopen of the app does (notch-island spec 2026-10-29 § 3.1, Reopen; owner
/// 2026-10-30): a click on an Omelette notification or a double click on the app in Finder,
/// with no window on screen, opens the island the way the notification route does; the
/// Dashboard opens only from the island's footer. With a window on screen (the Dashboard,
/// Settings) the reopen is left as it was. Pure: `AppDelegate.applicationShouldHandleReopen`
/// applies the answer.
enum ReopenRules {
    enum Action: Equatable, Sendable {
        /// Open the island, as `IslandController.handle(.notification)` does.
        case openIsland
        /// Nothing of ours: AppKit's and SwiftUI's own handling, as before.
        case leaveAlone

        /// What `applicationShouldHandleReopen` returns. True lets AppKit do its own reopen
        /// work, which with no visible window is the untitled-window path: SwiftUI answers it
        /// by bringing its first scene, the Dashboard's `Window`, forward, and that window
        /// turning key would close the island it just opened (ruling R7). So false whenever
        /// the island opens.
        var appKitHandlesReopen: Bool {
            self == .leaveAlone
        }
    }

    /// `hasVisibleWindows` is AppKit's flag, which counts windows, not panels: the island and
    /// the resting notch never count, the Dashboard and Settings do.
    static func action(hasVisibleWindows: Bool) -> Action {
        hasVisibleWindows ? .leaveAlone : .openIsland
    }
}
