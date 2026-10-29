import Foundation

/// Whether the status item is in the menu bar (notch-island spec 2026-10-29 § 3.7, § 3.9,
/// D4): Show in menu bar, off by default on a Mac with a notched display, and shown
/// regardless while no notched display is attached (clamshell, an external display only),
/// since the island has no other way in there. The ☾ ear while it is hidden is P6's. Pure.
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

    /// Under the switch: how to open Omelette without the item, or why the item stays.
    static func caption(notchedDisplayAttached: Bool) -> String {
        notchedDisplayAttached
            ? "Click the notch to open Omelette."
            : "Always on while no display with a notch is attached."
    }

    static func notchedDisplayAttached(_ screens: [IslandScreen]) -> Bool {
        screens.contains { $0.hasNotch }
    }
}
