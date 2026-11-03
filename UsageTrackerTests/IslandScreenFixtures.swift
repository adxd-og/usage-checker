import CoreGraphics
@testable import Omelette

/// Displays the island's rules are checked on (notch-island spec 2026-10-29 § 2, § 3.1; spec
/// 2026-11-03 § Virtual notch). `builtIn` is this Mac's 14-inch as measured on 2026-10-29
/// (advisory § 1): 1512 x 982 pt, notch 185 x 32, auxiliary areas 663.5 each, visible height 872
/// with the Dock. The others are arrangements the resolver has to handle: an external display to
/// the right, one to the left with negative x, a notched display narrower than 1420 pt, the two
/// externals with their menu bars hidden (no virtual notch: the panel), and displays at and one
/// point under the 1280 pt floor for a virtual notch.
enum ScreenFixture {
    static let builtIn = IslandScreen(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 872),
        safeAreaTop: 32,
        auxiliaryLeftWidth: 663.5,
        auxiliaryRightWidth: 663.5
    )

    /// 2560 x 1440 to the right of the built-in display, menu bar 24, no Dock.
    static let externalRight = IslandScreen(
        id: 2,
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1416),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )

    /// 1920 x 1080 to the left of the main display: every x is negative.
    static let externalLeft = IslandScreen(
        id: 3,
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1056),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )

    /// A notched display at a larger-text mode, 1352 x 878 pt: notch 192 x 34, Dock 70.
    static let narrowNotched = IslandScreen(
        id: 4,
        frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
        visibleFrame: CGRect(x: 0, y: 70, width: 1352, height: 774),
        safeAreaTop: 34,
        auxiliaryLeftWidth: 580,
        auxiliaryRightWidth: 580
    )

    /// `externalRight` with its menu bar hidden (auto-hide): the visible frame reaches the top, so
    /// the display shows no menu bar and gets no virtual notch. What a panel reads is as on
    /// `externalRight`: the visible frame's width and bottom, and a status item 24 pt down.
    static let externalRightMenuBarHidden = IslandScreen(
        id: 2,
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )

    /// `externalLeft` with its menu bar hidden.
    static let externalLeftMenuBarHidden = IslandScreen(
        id: 3,
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )

    /// 1280 x 800 to the right of the built-in display, menu bar 24, no Dock: the narrowest display
    /// with a virtual notch.
    static let wide1280 = IslandScreen(
        id: 12,
        frame: CGRect(x: 1512, y: 0, width: 1280, height: 800),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1280, height: 776),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )

    /// One point narrower than `wide1280`: no virtual notch, the panel.
    static let narrow1279 = IslandScreen(
        id: 13,
        frame: CGRect(x: 1512, y: 0, width: 1279, height: 800),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1279, height: 776),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )
}
