import AppKit

/// A resting pill on an island display other than the one carrying the ears (spec 2026-11-03
/// § Resting pill): its panel and the black notch shape it draws, which takes the click and reads
/// to VoiceOver as the Brioche button. P2 gives every pill the ears and the hint.
@MainActor
final class RestingPill {
    let displayID: UInt32
    let panel: RestingNotchPanel
    let notchView: RestingNotchView

    init(displayID: UInt32) {
        self.displayID = displayID
        panel = RestingNotchPanel.make()
        let root = RestingRootView(frame: .zero)
        root.autoresizesSubviews = true
        notchView = RestingNotchView(frame: root.bounds)
        notchView.autoresizingMask = [.width, .height]
        root.addSubview(notchView)
        panel.contentView = root
    }
}
