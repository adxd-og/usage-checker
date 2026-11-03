import CoreGraphics
import Foundation

/// One on-screen window as the WindowServer lists it (`CGWindowListCopyWindowInfo`): the three
/// fields that need no permission. The window's name is never read: it needs Screen Recording.
struct MenuBarWindow: Equatable, Sendable {
    /// `kCGWindowOwnerName`.
    let ownerName: String
    /// `kCGWindowLayer`.
    let layer: Int
    /// `kCGWindowBounds`: CG global coordinates, origin at the top left of the main display, y down.
    let boundsCG: CGRect
}

/// Each display's menu bar height (spec 2026-11-03, Amendment after the spike). The WindowServer
/// draws every display's menu bar as a window of its own at the main-menu level along the display's
/// top; a display without one (a full-screen space there, an auto-hidden bar) has no menu bar: 0.
/// The visible frame cannot tell: on a secondary display it reserves nothing for the menu bar. Pure;
/// `MenuBarWindowReader` lists the windows.
enum MenuBarWindowRules {
    /// The owner of the menu bar windows.
    static let ownerName = "Window Server"
    /// The main-menu window level (`kCGMainMenuWindowLevel`, 24), read once.
    static let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    /// How far a menu bar's top may sit from its display's top.
    private static let topTolerance: CGFloat = 1

    /// The menu bar height of each of `screens`, by display id; 0 for a display without a menu bar
    /// window. A window is a display's menu bar when it is the WindowServer's, at the main-menu
    /// level, with its top within a point of the display's top and its horizontal centre on the
    /// display; the first such window in `windows` gives the height. `mainDisplayHeight` is the main
    /// display's AppKit frame height, which turns the windows' CG bounds into AppKit ones.
    static func heights(
        windows: [MenuBarWindow], screens: [IslandScreen], mainDisplayHeight: CGFloat
    ) -> [UInt32: CGFloat] {
        let menuBars = windows.filter { $0.ownerName == ownerName && $0.layer == mainMenuLayer }
        var heights: [UInt32: CGFloat] = [:]
        for screen in screens {
            let menuBar = menuBars.first { isMenuBar($0, of: screen, mainDisplayHeight: mainDisplayHeight) }
            heights[screen.id] = menuBar?.boundsCG.height ?? 0
        }
        return heights
    }

    private static func isMenuBar(_ window: MenuBarWindow, of screen: IslandScreen, mainDisplayHeight: CGFloat) -> Bool {
        let bounds = window.boundsCG
        let appKit = CGRect(
            x: bounds.minX, y: mainDisplayHeight - (bounds.minY + bounds.height),
            width: bounds.width, height: bounds.height
        )
        return abs(appKit.maxY - screen.frame.maxY) <= topTolerance
            && appKit.midX >= screen.frame.minX && appKit.midX < screen.frame.maxX
    }
}

/// The on-screen windows, read now: the one part of the menu bar measurement that touches the
/// machine. Owner, layer and bounds need no permission; a list that cannot be read is no windows.
enum MenuBarWindowReader {
    static func onScreen() -> [MenuBarWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return MenuBarWindow(ownerName: owner, layer: layer, boundsCG: rect)
        }
    }
}
