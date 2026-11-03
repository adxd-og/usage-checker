import CoreGraphics
import Darwin
import Foundation

/// One on-screen window as the WindowServer lists it (`CGWindowListCopyWindowInfo`): the three
/// fields that need no permission. The window's name is never read: it needs Screen Recording.
struct MenuBarWindow: Equatable, Sendable {
    /// Its owner's process name, else `kCGWindowOwnerName` (`MenuBarWindowReader.ownerName`).
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
    /// The owner of the menu bar windows as the window list names it (`kCGWindowOwnerName`) on an
    /// English system.
    static let ownerName = "Window Server"
    /// The same owner by its process's name, which is not localized (4.1.0 release review OQ1).
    static let processName = "WindowServer"
    /// Either name owns the menu bar windows, matched exactly.
    static let ownerNames: Set<String> = [processName, ownerName]
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
        let menuBars = windows.filter { ownerNames.contains($0.ownerName) && $0.layer == mainMenuLayer }
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
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
            guard let owner = ownerName(
                      processName: pid.flatMap(processName(of:)),
                      listedName: info[kCGWindowOwnerName as String] as? String
                  ),
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return MenuBarWindow(ownerName: owner, layer: layer, boundsCG: rect)
        }
    }

    /// The name a window's owner goes by (4.1.0 release review OQ1): its process's name, which is not
    /// localized, else the name the window list gives (`kCGWindowOwnerName`, which may be); nil, and
    /// the window skipped, when neither is there. An empty name counts as none.
    static func ownerName(processName: String?, listedName: String?) -> String? {
        if let processName, !processName.isEmpty { return processName }
        if let listedName, !listedName.isEmpty { return listedName }
        return nil
    }

    /// `pid`'s process name (`pbsi_comm`), nil when it cannot be read. The short BSD info, because the
    /// full one (`proc_name`) is refused for another user's process, and the WindowServer runs as
    /// `_windowserver` (measured 2026-11-03: EPERM).
    private static func processName(of pid: pid_t) -> String? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pbsi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
