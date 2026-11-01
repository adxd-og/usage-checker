import AppKit

/// The island's window (notch-island spec 2026-10-29 § 3.1, The panel): borderless,
/// transparent and non-activating, on every space including full-screen ones, at the status
/// bar's level (P0 run 1: the help popover drew above the island there and took typing).
/// Its frame is fixed while open; the shape is drawn inside, and the mouse reaches the
/// window only inside the shape (`IslandController`).
final class IslandWindow: NSPanel {
    static func make() -> IslandWindow {
        let window = IslandWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.configureAsOverlay()
        window.acceptsMouseMovedEvents = true
        // Closed, the window takes no mouse at all.
        window.ignoresMouseEvents = true
        return window
    }

    /// Key on a click open, so typing, Tab, paste, ⌘A and Esc reach the island (§ 3.1, Focus).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The island sits over the menu bar; AppKit would push a constrained frame below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension NSPanel {
    /// What the island and the resting notch panel share: transparent, no shadow, never
    /// hidden when the app deactivates or is hidden (⌘H, with a real window up, has it in the
    /// Dock), fixed in place, no system animation, a click inside makes it key, at `.statusBar`,
    /// on every space including full-screen ones (§ 3.1; no full-screen detection, owner
    /// 2026-10-29).
    func configureAsOverlay() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}
