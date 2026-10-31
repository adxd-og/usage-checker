import Foundation

/// Whether the status item is in the menu bar (notch-island spec 2026-10-29 § 3.7, § 3.9,
/// D4): Show in menu bar, off by default on a Mac with a notched display, and shown
/// regardless while no notched display is attached (clamshell, an external display only),
/// since the island has no other way in there. While it is hidden, ☾ moves to the right ear (§ 3.6). Pure.
enum StatusItemVisibilityRules {
    /// `setting` is nil until the user flips the switch.
    static func isShown(setting: Bool?, notchedDisplayAttached: Bool) -> Bool {
        guard notchedDisplayAttached else { return true }
        return setting ?? false
    }

    /// The switch moves only while a notched display is attached; otherwise it reads on.
    static func switchEnabled(notchedDisplayAttached: Bool) -> Bool {
        notchedDisplayAttached
    }

    /// Under the switch: how to open Brioche without the item, or why the item stays.
    static func caption(notchedDisplayAttached: Bool) -> String {
        notchedDisplayAttached
            ? "Click the notch to open Brioche."
            : "Always on while no display with a notch is attached."
    }

    static func notchedDisplayAttached(_ screens: [IslandScreen]) -> Bool {
        screens.contains { $0.hasNotch }
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

    /// A 3.x user on a notched Mac has no stored setting and has seen the tour, so the item goes
    /// with nothing on screen in its place (whole-branch review of 4.0, ruling R1). The island opens
    /// once to say where the app went. A new install has the tour for that, and a stored setting is
    /// someone who has met the switch; neither needs it now or later. With no notched display the
    /// item is still there, so nothing has gone yet and a later launch decides.
    static func firstLaunchAfterUpdate(
        alreadyMarked: Bool, hasSeenOnboarding: Bool, setting: Bool?, notchedDisplayAttached: Bool
    ) -> FirstLaunchAfterUpdate {
        if alreadyMarked { return .nothing }
        if !hasSeenOnboarding || setting != nil { return .markOnly }
        return notchedDisplayAttached ? .openIsland : .nothing
    }

    /// ☾ moves to the right ear while keep awake is on and the item that would carry it is hidden.
    static func showsMoonEar(keepAwakeOn: Bool, itemShown: Bool) -> Bool {
        keepAwakeOn && !itemShown
    }
}
