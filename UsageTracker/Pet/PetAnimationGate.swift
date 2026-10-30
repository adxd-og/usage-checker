import Foundation

/// When the pet animates (notch-island spec 2026-10-29 § 3.5 "Animate only when", § 3.8
/// battery): its surface open (the island's transition `open`), the window not occluded, the
/// display awake, the screen not locked and Reduce Motion off. Otherwise the still frame and
/// no timeline at all, so a collapsed island's pet adds no timer and no wakeup. Settings ›
/// Pet's previews use the same gate with their window as the surface (§ 3.7). Pure.
enum PetAnimationGate {
    struct Conditions: Equatable, Sendable {
        /// The island's transition is `open` (`islandOpen`); for Settings' previews, their
        /// window is on screen.
        var surfaceOpen: Bool
        /// The window is not occluded (`WindowVisibilityReader`).
        var windowVisible: Bool
        var displayAwake: Bool
        var screenLocked: Bool
        var reduceMotion: Bool
    }

    static func animates(_ conditions: Conditions) -> Bool {
        conditions.surfaceOpen && conditions.windowVisible && conditions.displayAwake
            && !conditions.screenLocked && !conditions.reduceMotion
    }

    /// Only `open`: not while the shape grows and the content fades in, nor while it closes.
    static func islandOpen(_ phase: IslandTransition.Phase) -> Bool {
        phase == .open
    }

    /// The habitat's one `TimelineView` period at the playing animation's `fps`; nil (no
    /// timeline) whenever the gate is off or the rate is not a positive number.
    static func framePeriod(_ conditions: Conditions, fps: Double) -> TimeInterval? {
        guard animates(conditions), fps.isFinite, fps > 0 else { return nil }
        return 1 / fps
    }
}
