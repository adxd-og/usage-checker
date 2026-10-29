import AppKit
import SwiftUI

/// The notch-sized panel that stays at rest over the notch (notch-island spec 2026-10-29
/// § 3.1, Notch hint; D13): a click on the notch opens the island. It draws black over the
/// camera housing, where nothing shows, so the window server hands it the clicks there and
/// nowhere else. Never key: a notch click does not take focus from the app in front until
/// the island opens.
final class RestingNotchPanel: NSPanel {
    static func make() -> RestingNotchPanel {
        let panel = RestingNotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay()
        return panel
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// It sits on the menu bar; AppKit would push a constrained frame below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The resting panel's view: the black notch, the click on it, and the same press for
/// VoiceOver, which reads it as a button (§ 3.8: the notch click is always an entry point,
/// and on a notched Mac the status item is hidden by default). P6 adds the hover hint here
/// (D13: a tracking area over the notch, no timers); P1 has none.
final class RestingNotchView: NSView {
    /// The notch in this view, top-left origin (`IslandGeometry.restingPath`).
    var notchPath = Path() {
        didSet { needsDisplay = true }
    }
    /// A press on the notch, by mouse or VoiceOver; `option` is the ⌥ key (Debug's ear
    /// stand-in, `IslandEventRules.notchPressEntry`).
    var onPress: (@MainActor (_ option: Bool) -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(notchPath.cgPath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(event.modifierFlags.contains(.option))
    }

    // MARK: Accessibility: a button named Omelette, pressed as a click is

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { IslandEventRules.notchAccessibilityLabel }

    override func accessibilityPerformPress() -> Bool {
        onPress?(false)
        return true
    }
}
