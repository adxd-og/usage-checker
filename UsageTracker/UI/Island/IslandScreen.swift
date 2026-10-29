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

    /// Every attached display, read now.
    @MainActor
    static func current() -> [IslandScreen] {
        NSScreen.screens.map(IslandScreen.init)
    }
}
