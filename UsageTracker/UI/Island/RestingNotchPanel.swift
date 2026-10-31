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

/// The resting panel's view: the black shape (`RestingLayout`), the breath and the ear tips of the
/// hover hint (D13: a tracking area over the notch, no timers of its own), the click on it, and the
/// same press for VoiceOver, which reads it as a button (§ 3.8: the notch click is always an entry
/// point, and on a notched Mac the status item is hidden by default).
final class RestingNotchView: NSView {
    /// What to draw; nil before the first placing.
    var layout: RestingLayout? {
        didSet {
            guard layout != oldValue else { return }
            needsDisplay = true
            refreshTracking()
        }
    }
    /// The hint at this moment.
    var look = NotchHint.Look.rest {
        didSet {
            if look != oldValue { needsDisplay = true }
        }
    }
    /// While up, the tracked area is the grown shape, so moving into the breath is not a leave.
    var tracksHint = false {
        didSet {
            if tracksHint != oldValue { refreshTracking() }
        }
    }
    /// A press on the notch, by mouse or VoiceOver.
    var onPress: (@MainActor () -> Void)?
    /// The pointer came over the notch, or left it.
    var onHover: (@MainActor (Bool) -> Void)?

    private var tipsImage: NSImage?
    private var tipsSize = CGSize.zero
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pet's ear tips for the breath; nil with the pet off (the shape only, D13).
    func setTips(_ image: CGImage?, tips: PetEarTips?) {
        defer { needsDisplay = true }
        guard let image, let tips, let cropped = image.cropping(to: tips.crop) else {
            tipsImage = nil
            return
        }
        tipsImage = NSImage(cgImage: cropped, size: tips.size)
        tipsSize = tips.size
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        guard let layout else { return }
        context.addPath(layout.shape(look).cgPath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        if look.outlined {
            context.addPath(layout.outline().cgPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(RestingLayout.outlineOpacity).cgColor)
            context.setLineWidth(RestingLayout.outlineWidth)
            context.strokePath()
        }
        if look.down > 0, let tipsImage {
            NSGraphicsContext.current?.imageInterpolation = .none
            tipsImage.draw(
                in: layout.tipsRect(size: tipsSize, look: look), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    // MARK: Hover

    private func refreshTracking() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard let layout else { return }
        let area = NSTrackingArea(
            rect: layout.trackedRect(hintUp: tracksHint),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTracking()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    // MARK: Accessibility: a button named Omelette, pressed as a click is

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { IslandEventRules.notchAccessibilityLabel }

    override func accessibilityHelp() -> String? { IslandEventRules.notchAccessibilityHelp }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
