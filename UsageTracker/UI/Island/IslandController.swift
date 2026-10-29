import AppKit
import Combine
import SwiftUI

/// Opens and closes Omelette's window (notch-island spec 2026-10-29 § 3.1): the island grown
/// out of the notch, or a plain panel under the status item on a display without one. It
/// replaces 3.x's `NSPopover` and hosts today's popover content unchanged (§ 5, P1). Every
/// decision is a pure rule: `IslandDisplayResolver` (which display, which window),
/// `IslandGeometry` (the shape, where a click lands), `IslandEventRules` (what an entry or a
/// click does). This class reads AppKit's state and applies their answers. No motion until
/// P2: the window is ordered in and out (ruling R2).
@MainActor
final class IslandController: NSObject {
    private let window: IslandWindow
    private let model: IslandModel
    private let host: NSHostingView<IslandRootView<PopoverView>>
    /// The window's content while closed. The content leaves the window on every close and
    /// joins it on every open, as it did NSPopover's, so each open is an appearance: its
    /// `.task`s run again (hook status, the keep-awake fields' seed) and its timelines stop
    /// while closed (ruling R11).
    private let placeholder = NSView()
    /// The agents list's caps per tab (popover height budget spec 2026-10-27): told the
    /// screen before each open, written to `UserDefaults` when the island closes.
    private let heights: PopoverHeightModel

    private(set) var isOpen = false
    /// The current open's entry and placement; nil while closed.
    private var entry: IslandEntry?
    private var placement: IslandDisplayResolver.Placement?
    /// Event monitors, installed only while open: closed, the island adds no work (§ 3.8).
    private var monitors: [Any] = []
    private var contentSizeObserver: AnyCancellable?
    nonisolated(unsafe) private var showPopoverObserver: (any NSObjectProtocol)?

    /// The status item's window, so a click there is left to the item's own toggle (one
    /// action, one dismissal). Set by `StatusBarController`.
    var statusItemWindow: @MainActor () -> NSWindow? = { nil }

    override init() {
        let model = IslandModel()
        let heights = PopoverHeightModel(
            stored: UserDefaults.standard.string(forKey: PopoverHeightRules.fixedHeightsKey) ?? ""
        )
        self.model = model
        self.heights = heights
        self.window = IslandWindow.make()
        self.host = NSHostingView(rootView: IslandRootView(
            model: model,
            content: PopoverView(state: AppState.shared, heights: heights)
        ))
        super.init()
        // The window keeps the frame it is given; the content never resizes it.
        host.sizingOptions = []
        window.contentView = placeholder
        // `@Published` sends before the value lands: the hit test takes the sent size.
        contentSizeObserver = model.$contentSize
            .removeDuplicates()
            .sink { [weak self] size in
                self?.updateMouseIgnoring(contentSize: size)
            }
        // A notification the user acted on can name a session that has already ended; the
        // island is where the rest of them are.
        showPopoverObserver = NotificationCenter.default.addObserver(
            forName: .showPopover, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handle(.notification(pointer: NSEvent.mouseLocation))
            }
        }
    }

    deinit {
        if let observer = showPopoverObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Entries

    /// An entry point was used (§ 3.1, Entry points). `IslandEventRules.entry` says whether
    /// it opens, closes or keeps the island.
    func handle(_ entry: IslandEntry) {
        let screens = IslandScreen.current()
        let target = IslandDisplayResolver.display(for: entry, screens: screens, mainScreenID: CGMainDisplayID())
        switch IslandEventRules.entry(entry, isOpen: isOpen, openScreenID: placement?.screenID, entryScreenID: target?.id) {
        case .open:
            if let target { open(entry, on: target) }
        case .close:
            close()
        case .stay:
            if entry.becomesKey { makeKey() }
        }
    }

    /// Closes the island; nothing when it is closed.
    func close() {
        guard isOpen else { return }
        isOpen = false
        // From the first frame of a close the whole window ignores the mouse (P0 run 1).
        window.ignoresMouseEvents = true
        removeMonitors()
        window.orderOut(nil)
        window.contentView = placeholder
        entry = nil
        placement = nil
        persistPopoverHeights()
    }

    /// Writes each tab's fixed height and list floor when they changed, after a Reset all
    /// settings only those this session sampled. Also called as the app quits, because Quit
    /// in the footer ends the app with the island open.
    func persistPopoverHeights() {
        let key = PopoverHeightRules.fixedHeightsKey
        heights.persistNow(current: UserDefaults.standard.string(forKey: key)) {
            UserDefaults.standard.set($0, forKey: key)
        }
    }

    private func open(_ entry: IslandEntry, on screen: IslandScreen) {
        if isOpen { close() }
        AppState.shared.refreshForPopover()
        // Same moment, same reasoning as the refresh: the user is looking at the app, so this
        // is when an update is worth noticing. Throttled to once an hour inside the updater.
        Updater.shared.checkInBackgroundIfDue()
        // The screen it opens on, handed in before the content appears, so its first layout
        // already sizes the agents list for it (spec 2026-10-27).
        heights.setScreen(visibleHeight: Self.visibleHeight(of: screen))
        self.entry = entry
        // The shown status item, whatever opened the island: the panel hangs under it when it
        // is on this display (ruling R8).
        place(IslandDisplayResolver.placement(
            on: screen, entry: entry, statusItemFrame: statusItemWindow()?.frame,
            panelWidth: PopoverView.width, menuBarHeight: Self.menuBarHeight
        ))
        window.contentView = host
        isOpen = true
        if entry.becomesKey {
            makeKey()
        } else {
            window.orderFrontRegardless()
        }
        installMonitors()
        updateMouseIgnoring()
    }

    /// Opened by a click: key, with the content as first responder, so typing, Tab, paste,
    /// ⌘A and Esc reach the island and never the app behind (§ 3.1, Focus). P0: works with
    /// Safari, iTerm2 or Finder in front, without activating the app.
    private func makeKey() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
    }

    // MARK: - Placement

    private func place(_ placement: IslandDisplayResolver.Placement) {
        self.placement = placement
        // The island is the notch grown, always dark; the panel follows the system (§ 3.1).
        window.appearance = placement.kind == .island ? NSAppearance(named: .darkAqua) : nil
        window.setFrame(placement.windowFrame, display: false)
        // From the frame AppKit applied: it may snap a half-point origin (P0: 656.5 → 656.0).
        model.geometry = IslandGeometry(placement: placement, appliedFrame: window.frame)
    }

    /// The menu bar's height, for a panel on a display whose menu bar hides. An accessory
    /// app may have no main menu to ask; the status bar's thickness stands in.
    private static var menuBarHeight: CGFloat {
        NSApp.mainMenu.map(\.menuBarHeight).flatMap { $0 > 0 ? $0 : nil } ?? NSStatusBar.system.thickness
    }

    /// What `PopoverHeightRules` budgets the agents list against on `screen`.
    private static func visibleHeight(of screen: IslandScreen) -> CGFloat {
        PopoverHeightRules.screenVisibleHeight(
            frameMaxY: screen.frame.maxY,
            visibleFrameMaxY: screen.visibleFrame.maxY,
            visibleFrameHeight: screen.visibleFrame.height,
            menuBarHeight: menuBarHeight
        )
    }

    // MARK: - Clicks through the transparent part

    /// The window takes the mouse only while the pointer is inside the shape, checked on
    /// every mouse move and whenever the shape changes (P0 run 1, strategy B: 0 misses).
    private func updateMouseIgnoring(contentSize: CGSize? = nil) {
        guard isOpen, let geometry = model.geometry else { return }
        let point = IslandGeometry.windowPoint(screenPoint: NSEvent.mouseLocation, windowFrame: window.frame)
        let inside = geometry.region(of: point, contentSize: contentSize ?? model.contentSize) != .outside
        if window.ignoresMouseEvents == inside {
            window.ignoresMouseEvents = !inside
        }
    }

    private func installMonitors() {
        removeMonitors()
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Over the island's own window while it takes the mouse.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.updateMouseIgnoring()
            return event
        }) {
            monitors.append(monitor)
        }
        // Everywhere else, including over the island while it ignores the mouse.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.updateMouseIgnoring()
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }
}
