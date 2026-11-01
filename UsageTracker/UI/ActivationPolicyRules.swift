import AppKit

/// When the app is in Cmd+Tab, with a Dock icon and its menu bar: while one of its real windows
/// (the Dashboard, Settings, the tour) is up. Otherwise it stays the accessory `LSUIElement`
/// makes it. Pure: `ActivationPolicyController` reads the facts and applies the answer.
enum ActivationPolicyRules {
    /// What AppKit reports about one window, at this moment.
    struct WindowFacts: Equatable, Sendable {
        var isPanel: Bool
        var isTitled: Bool
        var isSheet: Bool
        var hasParent: Bool
        var canBecomeMain: Bool
        var isVisible: Bool
        var isMiniaturized: Bool
    }

    /// A window someone would want to get back to. Panels are out, which is the island, the
    /// resting notch and its ears, the floating mini window and AppKit's own panels; borderless is
    /// out, which is the status item's window, popovers and SwiftUI's helpers; sheets and children
    /// go with their parent. `isVisible`, not occlusion: a covered window or one on another Space
    /// is still there to switch to. A closed SwiftUI `Window` is hidden, not destroyed, and
    /// reads not visible. `canBecomeMain` applies only on screen, since AppKit answers false for
    /// a window in the Dock (measured on macOS 27).
    nonisolated static func isRealWindow(_ window: WindowFacts) -> Bool {
        guard window.isTitled, !window.isPanel, !window.isSheet, !window.hasParent else { return false }
        return window.isMiniaturized || (window.isVisible && window.canBecomeMain)
    }

    /// The policy for these windows. A hidden app keeps the one it has: ⌘H orders every window
    /// out (measured: `isVisible` false, `isMiniaturized` false), and leaving the switcher then
    /// would take the Dock icon and Cmd+Tab, the ways back, with it.
    nonisolated static func policy(
        windows: [WindowFacts], appIsHidden: Bool, current: NSApplication.ActivationPolicy
    ) -> NSApplication.ActivationPolicy {
        if appIsHidden { return current }
        return windows.contains(where: isRealWindow) ? .regular : .accessory
    }

    /// Whether to ask for activation after changing to `policy`. Every way of opening a window
    /// activates first, so an app already active asks again and its menu bar comes up with
    /// the change; an inactive one has a window that showed by itself, and takes no keyboard
    /// from the app in front. Leaving the switcher asks for nothing: AppKit deactivates the
    /// app there (measured), and the app that was in front before takes the keyboard back.
    nonisolated static func activatesAfterChange(
        to policy: NSApplication.ActivationPolicy, appIsActive: Bool
    ) -> Bool {
        policy == .regular && appIsActive
    }
}
