import CoreGraphics

/// The notch a display without one gets (spec 2026-11-03 § Virtual notch): a black pill in the
/// middle of its menu bar, as tall as the menu bar and as wide as the camera housing of the notched
/// display attached, so the island looks the same on every display. None where the menu bar is
/// hidden, or on a display too narrow for a busy app's menus to leave the middle free. Pure; the
/// constants are the owner's to tune after the look (spec OQ 1, OQ 2).
enum VirtualNotchRules {
    /// The pill's width with no notched display attached (the lid closed, a Mac without a notch):
    /// the 14-inch MacBook Pro's notch at its default mode (spec OQ 2).
    static let fallbackWidth: CGFloat = 185
    /// Narrower displays get no pill: the menus of a busy app reach the middle there (spec OQ 1).
    static let minimumScreenWidth: CGFloat = 1280

    /// Centred on `screen`'s frame, from its top edge down by its menu bar's height, as wide as
    /// `referenceNotchWidth` (the attached camera housing's), else `fallbackWidth`. nil when the
    /// menu bar is hidden (height 0) or the display is narrower than `minimumScreenWidth`. A camera
    /// housing on `screen` is not looked at: `IslandScreen.islandNotch` prefers it.
    static func rect(screen: IslandScreen, referenceNotchWidth: CGFloat?) -> CGRect? {
        let height = screen.menuBarHeight
        guard height > 0, screen.frame.width >= minimumScreenWidth else { return nil }
        let width = referenceNotchWidth.flatMap { $0 > 0 ? $0 : nil } ?? fallbackWidth
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }
}
