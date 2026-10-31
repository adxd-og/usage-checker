import Foundation

/// What an entry, a click, a window turning key or a key press does to the island
/// (notch-island spec 2026-10-29 § 3.1: Clicks, Focus, Dismissal, Entry points). Pure: the
/// controller sorts AppKit's events into these cases and applies the answer.
enum IslandEventRules {
    /// Where a mouse-down in one of Omelette's own windows landed (the local monitor).
    enum ClickTarget: Equatable, Sendable {
        /// The island's window, by `IslandGeometry.Region`.
        case island(IslandGeometry.Region)
        /// The status item: its own action toggles.
        case statusItem
        /// The resting notch panel: its own click opens.
        case restingNotch
        /// A help popover, a menu, or another window attached to the island.
        case childOfIsland
        /// Dashboard, Settings, the floating window, onboarding.
        case otherWindow
        /// An event without a window.
        case noWindow
    }

    enum ClickVerdict: Equatable, Sendable {
        /// The island stays; the click goes on.
        case pass
        /// The island closes; the click still reaches its window.
        case close
        /// The island closes and the click goes nowhere.
        case closeAndSwallow
    }

    static func localClick(_ target: ClickTarget) -> ClickVerdict {
        switch target {
        case .island(.body):
            return .pass
        case .island(.notchStrip):
            // The same spot that opened it (§ 3.1, Dismissal).
            return .closeAndSwallow
        case .island(.outside):
            // A deliberate fallback for a stale `ignoresMouseEvents`, not the click-through path.
            return .closeAndSwallow
        case .statusItem, .restingNotch:
            // One action, one dismissal: their own handlers toggle.
            return .pass
        case .childOfIsland, .noWindow:
            return .pass
        case .otherWindow:
            return .close
        }
    }

    enum EntryVerdict: Equatable, Sendable {
        case open
        case close
        /// Already open: stays, and takes key when the entry gives key.
        case stay
    }

    /// `openScreenID` is where the island is open; `entryScreenID` where the entry would put
    /// it. The status item toggles wherever the island is; the notch closes the island open
    /// on its display and moves one open elsewhere (ruling R6); a notification leaves the
    /// island open on its display and moves it to the pointer's display (ruling R5); an ear
    /// leaves an island open on its display open, and moves one open elsewhere (P6 plan R5).
    static func entry(_ entry: IslandEntry, isOpen: Bool, openScreenID: UInt32?, entryScreenID: UInt32?) -> EntryVerdict {
        guard isOpen else { return .open }
        switch entry {
        case .statusItem:
            return .close
        case .notch:
            return openScreenID == entryScreenID ? .close : .open
        case .notification:
            return openScreenID == entryScreenID ? .stay : .open
        case .ear:
            return openScreenID == entryScreenID ? .stay : .open
        }
    }

    /// Another Omelette window turning key closes the island: Dashboard or Settings opening
    /// from its footer, the floating window, onboarding (ruling R7). Its own children do not.
    static func closesOnKeyWindow(isIsland: Bool, isChildOfIsland: Bool) -> Bool {
        !isIsland && !isChildOfIsland
    }

    /// The island's child windows count as inside it (§ 3.1): attached to it, or a popover or
    /// a menu, which only the island opens while it is up (the spike's rule, ruling R17).
    static func isChildOfIsland(parentIsIsland: Bool, listedAsChild: Bool, className: String) -> Bool {
        parentIsIsland || listedAsChild || className.contains("Popover") || className.contains("Menu")
    }

    /// Esc's key code.
    static let escapeKeyCode: UInt16 = 53

    /// A key the island's navigation answers (§ 3.4, § 3.8).
    enum NavigationKey: Equatable, Sendable {
        case escape
        /// ⌘ and a digit, 0–9.
        case digit(Int)

        /// What `IslandNavigation` is told.
        var input: IslandNavigation.Input {
            switch self {
            case .escape: .escape
            case .digit(let digit): .shortcut(digit)
            }
        }
    }

    /// The top row's digits and the keypad's by key code (`kVK_ANSI_*`), so ⌘1 is the key
    /// marked 1 whatever the keyboard layout.
    static let digitKeyCodes: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// Esc, or ⌘ alone with a digit, while the island is the key window; nil for everything
    /// else: a digit typed into a field, ⌘ with ⇧ ⌥ or ⌃ (another shortcut), the footer's
    /// ⌘D / ⌘, / ⌘R / ⌘Q, and any key while another window is key (a help popover takes its
    /// own Esc).
    static func navigationKey(
        keyCode: UInt16, command: Bool, shift: Bool, option: Bool, control: Bool, keyWindowIsIsland: Bool
    ) -> NavigationKey? {
        guard keyWindowIsIsland else { return nil }
        if keyCode == escapeKeyCode { return .escape }
        guard command, !shift, !option, !control, let digit = digitKeyCodes[keyCode] else { return nil }
        return .digit(digit)
    }

    /// What the island's key monitor does with a key.
    enum KeyRoute: Equatable, Sendable {
        /// Applied by the navigation, and swallowed.
        case navigate(IslandNavigation.Input)
        /// Swallowed with nothing done.
        case swallow
        /// Not the island's: it goes on.
        case pass
    }

    /// A navigation key (`navigationKey`, only ever non-nil while the island is the key window)
    /// is the island's in every phase: applied while it is open, swallowed while it closes — a
    /// ⌘ digit or ⌘Esc must not slip through `IslandTransition.swallowsKey`'s ⌘ exemption and
    /// reach AppKit, which beeps (owner 2026-10-30; Codex review finding 2). Any other key
    /// follows the closing rule: swallowed when `closingSwallows` (a plain key aimed at a closing
    /// island), else it goes on (⌘Q, ⌘C / ⌘V in a field).
    static func keyRoute(_ key: NavigationKey?, isOpen: Bool, closingSwallows: Bool) -> KeyRoute {
        if let key { return isOpen ? .navigate(key.input) : .swallow }
        return closingSwallows ? .swallow : .pass
    }

    /// What a local event monitor hands back to AppKit: the handler's answer, nil included,
    /// so a swallowed Esc or notch-strip click stays swallowed. `?? event` would revive it:
    /// in the spike the revived Esc went down the responder chain and the Mac beeped. With
    /// no handler left (the controller is gone) the event goes on.
    @MainActor
    static func forward<Event>(_ event: Event, to handler: (@MainActor (Event) -> Event?)?) -> Event? {
        guard let handler else { return event }
        return handler(event)
    }

    /// The entry a press on the bare notch makes, by mouse or VoiceOver: the notch. In a Debug
    /// build an ⌥-click stands in for an ear until P6 (ruling R4).
    static func notchPressEntry(option: Bool, debugBuild: Bool) -> IslandEntry {
        option && debugBuild ? .ear : .notch
    }

    /// What VoiceOver reads for the notch, a button (§ 3.8: the notch click is always an entry
    /// point, and on a notched Mac the status item is hidden by default).
    static let notchAccessibilityLabel = "Omelette"
    /// What the button does, as VoiceOver's hint.
    static let notchAccessibilityHelp = "Opens Omelette. Press again to close it."
}
