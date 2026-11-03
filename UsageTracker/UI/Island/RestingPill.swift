import AppKit

/// What an ear's head and the hint's ear tips are drawn from on one pill: the chosen pet's head at
/// that display's scale.
struct RestingHead {
    let image: CGImage
    let scale: PetScaleRules.Scale
}

/// One island display's resting pill (spec 2026-11-03 § Resting pill, § Ears and hint): its panel,
/// the black shape over the notch that takes the click, the ears attached to it, and the pill's own
/// hover hint, so the breath and the pet's ear tips show only on the pill under the pointer. The
/// controller keeps one per island display, keyed by display id, and decides everything; this holds
/// the views and the hint's state.
@MainActor
final class RestingPill {
    let displayID: UInt32
    let panel: RestingNotchPanel
    let notchView: RestingNotchView
    let leftEarView = RestingEarView(frame: .zero)
    let rightEarView = RestingEarView(frame: .zero)
    /// The hover hint on this pill (D13): its value, its frames while the spring moves (a display
    /// link on this pill's view, so at its display's rate), and the one wait an arrival arms.
    var hint = NotchHint()
    let hintFrames: IslandFrameDriver
    var hintDelay: Task<Void, Never>?
    var lastHintFrameTime: TimeInterval?
    /// The window holds the hint's room.
    var room = false
    /// The head this pill's ear and tips draw, at its display's scale; nil with the pet off or
    /// before it is built.
    private(set) var head: RestingHead?

    init(displayID: UInt32) {
        self.displayID = displayID
        let notchView = RestingNotchView(frame: .zero)
        self.notchView = notchView
        panel = RestingNotchPanel.make()
        hintFrames = IslandFrameDriver(source: DisplayLinkFrameSource(view: notchView))
        // Every stored property is set from here on.
        let root = RestingRootView(frame: .zero)
        root.autoresizesSubviews = true
        notchView.frame = root.bounds
        notchView.autoresizingMask = [.width, .height]
        root.addSubview(notchView)
        root.addSubview(leftEarView)
        root.addSubview(rightEarView)
        leftEarView.isHidden = true
        rightEarView.isHidden = true
        panel.contentView = root
    }

    /// What the ears show on this display.
    func show(_ ears: IslandEars) {
        switch ears.left?.mark {
        case .head: leftEarView.content = .head
        case .neutralDot: leftEarView.content = .dot
        case nil: leftEarView.content = nil
        }
        leftEarView.label = ears.left?.label
        switch ears.right?.mark {
        case .number(let lines): rightEarView.content = .number(lines: lines)
        case .moon: rightEarView.content = .moon
        case nil: rightEarView.content = nil
        }
        rightEarView.label = ears.right?.label
    }

    /// The head for the left ear and the hint's ear tips; nil clears both.
    func showArt(_ head: RestingHead?, tips: PetEarTips?) {
        self.head = head
        notchView.setTips(head?.image, tips: tips)
        leftEarView.setHead(head?.image, scale: head?.scale)
    }

    /// The ears' content where the black is at this moment of the breath.
    func placeEars() {
        guard let layout = notchView.layout else { return }
        leftEarView.frame = layout.earFrame(layout.leftEar, look: notchView.look)
        rightEarView.frame = layout.earFrame(layout.rightEar, look: notchView.look)
    }

    /// The display went away or lost its island: no wait, no frames, no window.
    func close() {
        hintDelay?.cancel()
        hintDelay = nil
        hintFrames.stop()
        panel.orderOut(nil)
        panel.close()
    }
}
