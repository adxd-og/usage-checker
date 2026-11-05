import Foundation

/// Whether the status item is in the menu bar (notch-island spec 2026-10-29 § 3.7, § 3.9, D4; spec
/// 2026-11-03 § Status item): Show in menu bar, off by default while a display shows the island — a
/// notch, or the pill on a display without one — and shown regardless while none does (every menu
/// bar hidden, only displays under 1280 pt, or no camera housing with Island on displays without a
/// notch off, § P4), since the island has no other way in there. While it is hidden, ☾ moves to the
/// right ear (§ 3.6). Pure.
enum StatusItemVisibilityRules {
    /// `setting` is nil until the user flips the switch.
    static func isShown(setting: Bool?, islandDisplayAttached: Bool) -> Bool {
        guard islandDisplayAttached else { return true }
        return setting ?? false
    }

    /// The switch moves only while a display shows the island; otherwise it reads on.
    static func switchEnabled(islandDisplayAttached: Bool) -> Bool {
        islandDisplayAttached
    }

    /// Under the switch: how to open Brioche without the item, or why the item stays.
    static func caption(islandDisplayAttached: Bool) -> String {
        islandDisplayAttached
            ? "Click the island at the top of the screen to open Brioche."
            : "Always on while no display shows the island."
    }

    /// Some display carries an island notch, physical or virtual (`IslandScreen.islandNotch`).
    static func islandDisplayAttached(_ screens: [IslandScreen]) -> Bool {
        screens.contains { $0.islandNotch != nil }
    }

    /// What a launch does about a status item that went away with an update.
    enum FirstLaunchAfterUpdate: Equatable, Sendable {
        /// The island opens, so the app is not simply gone, and the marker is stored.
        case openIsland
        /// Nothing opens, now or later: the marker is stored.
        case markOnly
        /// Nothing, and no marker: a later launch decides.
        case nothing
    }

    /// A 3.x user on a notched Mac, or a 4.0 user on a setup without one (the item was forced on
    /// there; spec 2026-11-03), has no stored setting and has seen the tour, so the item goes with
    /// nothing on screen in its place (whole-branch review of 4.0, ruling R1). The island opens once
    /// to say where the app went. A new install has the tour for that, and a stored setting is
    /// someone who has met the switch; neither needs it now or later. With no display showing the
    /// island the item is still there, so nothing has gone yet and a later launch decides.
    static func firstLaunchAfterUpdate(
        alreadyMarked: Bool, hasSeenOnboarding: Bool, setting: Bool?, islandDisplayAttached: Bool
    ) -> FirstLaunchAfterUpdate {
        if alreadyMarked { return .nothing }
        if !hasSeenOnboarding || setting != nil { return .markOnly }
        return islandDisplayAttached ? .openIsland : .nothing
    }

    /// ☾ moves to the right ear while keep awake is on and the item that would carry it is hidden.
    static func showsMoonEar(keepAwakeOn: Bool, itemShown: Bool) -> Bool {
        keepAwakeOn && !itemShown
    }
}
