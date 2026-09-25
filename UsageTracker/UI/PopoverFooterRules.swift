import Foundation

/// What the popover's footer can do (`Main.dc.html`).
enum PopoverAction: CaseIterable, Sendable {
    case dashboard, floatingWindow, settings, refresh, quit
}

/// The footer: Dashboard, the floating window and Settings as glass buttons, then
/// Quit. Refresh keeps ⌘R and loses its button (spec § Screens, "Popover · All").
/// No version link: Settings → General carries the version and the GitHub link.
enum PopoverFooterRules {
    /// The glass buttons, left to right.
    static let buttons: [PopoverAction] = [.dashboard, .floatingWindow, .settings]
    /// What follows the spacer: Quit, and nothing else.
    static let trailing: [PopoverAction] = [.quit]
    /// Reached by keyboard only.
    static let keyboardOnly: [PopoverAction] = [.refresh]
    static let spacing: CGFloat = 8

    /// ⌘ plus this key.
    static func shortcutKey(_ action: PopoverAction) -> Character? {
        switch action {
        case .dashboard: "d"
        case .settings: ","
        case .refresh: "r"
        case .quit: "q"
        case .floatingWindow: nil
        }
    }

    /// The SF Symbol for the action (`Main.dc.html`: a sidebar window, a picture in a
    /// picture, sliders).
    static func symbol(_ action: PopoverAction, floatingWindowOpen: Bool = false) -> String {
        switch action {
        case .dashboard: "sidebar.left"
        case .floatingWindow: floatingWindowOpen ? "pip.exit" : "pip.enter"
        case .settings: "slider.horizontal.3"
        case .refresh: "arrow.clockwise"
        case .quit: "power"
        }
    }

    /// The button's title; the circle buttons show only the icon, and VoiceOver reads this.
    static func title(_ action: PopoverAction) -> String {
        switch action {
        case .dashboard: "Dashboard"
        case .floatingWindow: "Floating window"
        case .settings: "Settings"
        case .refresh: "Refresh now"
        case .quit: "Quit"
        }
    }

    static func help(_ action: PopoverAction, floatingWindowOpen: Bool = false) -> String {
        switch action {
        case .dashboard: "Open dashboard (⌘D)"
        case .floatingWindow: floatingWindowOpen ? "Close floating window" : "Show floating mini window"
        case .settings: "Settings (⌘,)"
        case .refresh: "Refresh now (⌘R)"
        case .quit: "Quit Omelette (⌘Q)"
        }
    }
}
