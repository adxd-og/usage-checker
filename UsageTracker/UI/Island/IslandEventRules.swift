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
    /// leaves an open island open.
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
            return .stay
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

    /// Esc closes the island while it is the key window, from any tab (ruling R3; P3b's
    /// navigation turns Esc in a provider page into Back). A key help popover takes its own.
    static func escapeCloses(keyCode: UInt16, keyWindowIsIsland: Bool) -> Bool {
        keyCode == escapeKeyCode && keyWindowIsIsland
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
}
