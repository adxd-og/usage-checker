import AppKit

/// One display as the island's rules read it (notch-island spec 2026-10-29 § 3.1, Display
/// and anchor): the values its `NSScreen` reports, copied, so the rules stay pure. Global
/// AppKit coordinates: origin at the bottom left of the main display, y up; a display left
/// of it has negative x.
struct IslandScreen: Equatable, Sendable {
    /// `CGDirectDisplayID`.
    let id: UInt32
    let frame: CGRect
    let visibleFrame: CGRect
    /// `safeAreaInsets.top`: the camera housing's height on a notched display, 0 elsewhere.
    let safeAreaTop: CGFloat
    /// The widths of `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, the menu bar either
    /// side of the notch; nil when the display has none.
    let auxiliaryLeftWidth: CGFloat?
    let auxiliaryRightWidth: CGFloat?
    /// The camera housing's width on the notched display read with this one (`attached`): the width
    /// a virtual notch takes (spec 2026-11-03). nil with no notched display attached, and on a
    /// reading not passed through `attached`.
    var referenceNotchWidth: CGFloat? = nil
    /// Device pixels per point (`NSScreen.backingScaleFactor`): with the notch's height, whether the
    /// pet's whole-pixel head fits an ear on this display (spec 2026-11-03 § Ears and hint). A value
    /// built by hand is 2×, a Retina display, unless it says otherwise.
    var backingScale: CGFloat = 2

    /// The camera housing, from this reading: as tall as the top safe area, as wide as the
    /// two auxiliary areas leave. Only their widths are used, so the answer does not depend
    /// on the space AppKit reports the areas in (P0). nil without a notch. Read on every
    /// open, never cached: its size in points changes with the display mode.
    var notchRect: CGRect? {
        guard safeAreaTop > 0,
              let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth,
              left > 0, right > 0
        else { return nil }
        let width = frame.width - left - right
        guard width > 0 else { return nil }
        return CGRect(x: frame.minX + left, y: frame.maxY - safeAreaTop, width: width, height: safeAreaTop)
    }

    var hasNotch: Bool { notchRect != nil }

    /// The menu bar's height on this display: what the visible frame leaves at the top (spec
    /// 2026-11-03 § Virtual notch). 0 while the menu bar is hidden there (auto-hide, or a display
    /// without a menu bar of its own).
    var menuBarHeight: CGFloat { max(frame.maxY - visibleFrame.maxY, 0) }

    /// Where the island hangs (spec 2026-11-03 § Virtual notch): the camera housing on a notched
    /// display, else the virtual notch from `VirtualNotchRules`; nil on a display with neither,
    /// where the island is the panel. `hasNotch` still says whether there is a camera housing.
    var islandNotch: CGRect? {
        notchRect ?? VirtualNotchRules.rect(screen: self, referenceNotchWidth: referenceNotchWidth)
    }
}

extension IslandScreen {
    /// `screen` as it reports itself now.
    @MainActor
    init(_ screen: NSScreen) {
        self.init(
            id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            backingScale: screen.backingScaleFactor
        )
    }

    /// Every attached display, read now, as one reading (`attached`).
    @MainActor
    static func current() -> [IslandScreen] {
        attached(NSScreen.screens.map(IslandScreen.init))
    }

    /// `screens` as one reading: each display carries the width of the first camera housing among
    /// them, so a virtual notch matches the physical one (spec 2026-11-03 § Virtual notch). The
    /// order and every other value are kept.
    static func attached(_ screens: [IslandScreen]) -> [IslandScreen] {
        let width = screens.lazy.compactMap(\.notchRect).first?.width
        return screens.map { screen in
            var screen = screen
            screen.referenceNotchWidth = width
            return screen
        }
    }
}
