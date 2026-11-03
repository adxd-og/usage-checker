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
    /// The height of this display's menu bar window (`MenuBarWindowRules`), 0 without one; set on a
    /// reading passed through `attached(_:menuBarWindows:)`, as every live one is. nil elsewhere.
    var measuredMenuBarHeight: CGFloat? = nil

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

    /// The menu bar's height on this display (spec 2026-11-03 § Virtual notch, Amendment after the
    /// spike): the measured height of its menu bar window, 0 while there is none (a full-screen space,
    /// an auto-hidden bar). A reading without a measurement falls back on what the visible frame
    /// leaves at the top, which on a secondary display is always 0.
    var menuBarHeight: CGFloat { measuredMenuBarHeight ?? max(frame.maxY - visibleFrame.maxY, 0) }

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
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width
        )
    }

    /// Every attached display, read now, with the menu bar windows on screen now, as one reading
    /// (`attached(_:menuBarWindows:)`).
    @MainActor
    static func current() -> [IslandScreen] {
        attached(NSScreen.screens.map(IslandScreen.init), menuBarWindows: MenuBarWindowReader.onScreen())
    }

    /// `screens` as one reading (`attached`), each display's menu bar height measured from
    /// `menuBarWindows` (`MenuBarWindowRules`), 0 for a display without a menu bar window. The first
    /// of `screens` is the main display, as in `NSScreen.screens`: its height relates the windows'
    /// CG bounds to the displays' AppKit frames.
    static func attached(_ screens: [IslandScreen], menuBarWindows: [MenuBarWindow]) -> [IslandScreen] {
        let heights = MenuBarWindowRules.heights(
            windows: menuBarWindows, screens: screens, mainDisplayHeight: screens.first?.frame.height ?? 0
        )
        return attached(screens).map { screen in
            var screen = screen
            screen.measuredMenuBarHeight = heights[screen.id] ?? 0
            return screen
        }
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
