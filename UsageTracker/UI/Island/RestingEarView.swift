import AppKit
import SwiftUI

/// The resting panel's content view: top-left coordinates, as `RestingLayout` gives them. The notch's
/// view and the ears are siblings, each one VoiceOver button.
final class RestingRootView: NSView {
    override var isFlipped: Bool { true }
}

/// One ear (notch-island spec 2026-10-29 § 3.6): what it shows, on the black the notch's view draws,
/// the click on it, and the same press for VoiceOver. What it shows and does is `IslandEarRules`'.
final class RestingEarView: NSView {
    enum Content: Equatable {
        case head
        case dot
        case number(lines: [String])
        case moon
    }

    /// Nil: no ear, nothing to hit.
    var content: Content? {
        didSet {
            isHidden = content == nil
            needsDisplay = true
        }
    }
    var label: String?
    /// While the morph carries the head.
    var hidesHead = false {
        didSet {
            if hidesHead != oldValue { needsDisplay = true }
        }
    }
    var onPress: (@MainActor () -> Void)?

    private var headImage: NSImage?
    private var headScale: PetScaleRules.Scale?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setHead(_ image: CGImage?, scale: PetScaleRules.Scale?) {
        defer { needsDisplay = true }
        guard let image, let scale else {
            headImage = nil
            headScale = nil
            return
        }
        let side = scale.points(beads: PetContract.earSize)
        headImage = NSImage(cgImage: image, size: CGSize(width: side, height: side))
        headScale = scale
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .head:
            guard !hidesHead, let headImage, let headScale else { return }
            NSGraphicsContext.current?.imageInterpolation = .none
            headImage.draw(
                in: IslandEarRules.headRect(in: bounds, scale: headScale), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
        case .dot:
            let side = IslandEarRules.neutralDotSize
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)).fill()
        case .number(let lines):
            drawCentred(
                lines.joined(separator: "\n"),
                font: IslandEarRules.numberFont(size: IslandEarRules.numberSize(lines: lines)),
                color: NSColor(OMPalette.rgba(IslandEarRules.numberToken, scheme: .dark).color)
            )
        case .moon:
            drawCentred(KeepAwakeCopy.menuBarGlyph, font: IslandEarRules.numberFont(size: 15), color: .white)
        case nil:
            break
        }
    }

    private func drawCentred(_ text: String, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = string.size().height
        string.draw(in: CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height))
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    // MARK: Accessibility: a button named for what it says, pressed as a click is

    override func isAccessibilityElement() -> Bool { content != nil }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { label }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
