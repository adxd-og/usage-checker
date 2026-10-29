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
    /// The notch-sized panel at rest over the notch (D13), and its view.
    private let resting: RestingNotchPanel
    private let restingView: RestingNotchView

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
        self.resting = RestingNotchPanel.make()
        self.restingView = RestingNotchView(frame: .zero)
        self.host = NSHostingView(rootView: IslandRootView(
            model: model,
            content: PopoverView(state: AppState.shared, heights: heights)
        ))
        super.init()
        // The window keeps the frame it is given; the content never resizes it.
        host.sizingOptions = []
        resting.contentView = restingView
        restingView.onPress = { [weak self] option in
            self?.notchPressed(option: option)
        }
        placeResting(IslandScreen.current())
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
        // Dashboard, Settings or any other Omelette window turning key closes the island.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        observeDisplays()
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
    /// Safari, iTerm2 or Finder in front; the island turning key makes Omelette active.
    private func makeKey() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
    }

    // MARK: - Dismissal

    /// A mouse-down in one of Omelette's own windows while the island is open (§ 3.1).
    private func localClick(_ event: NSEvent) -> NSEvent? {
        guard isOpen else { return event }
        switch IslandEventRules.localClick(clickTarget(of: event)) {
        case .pass:
            return event
        case .close:
            close()
            return event
        case .closeAndSwallow:
            close()
            return nil
        }
    }

    private func clickTarget(of event: NSEvent) -> IslandEventRules.ClickTarget {
        guard let target = event.window else { return .noWindow }
        if target === window, let geometry = model.geometry {
            let point = IslandGeometry.windowPoint(
                screenPoint: window.convertPoint(toScreen: event.locationInWindow),
                windowFrame: window.frame
            )
            return .island(geometry.region(of: point, contentSize: model.contentSize))
        }
        if target === resting { return .restingNotch }
        if target === statusItemWindow() { return .statusItem }
        if isChildOfIsland(target) { return .childOfIsland }
        return .otherWindow
    }

    /// A help popover, a menu, or any window attached to the island counts as inside it.
    private func isChildOfIsland(_ other: NSWindow) -> Bool {
        IslandEventRules.isChildOfIsland(
            parentIsIsland: other.parent === window,
            listedAsChild: window.childWindows?.contains(where: { $0 === other }) == true,
            className: other.className
        )
    }

    /// Esc closes the island while it is the key window; a key help popover takes its own.
    private func keyDown(_ event: NSEvent) -> NSEvent? {
        guard isOpen,
              IslandEventRules.escapeCloses(keyCode: event.keyCode, keyWindowIsIsland: NSApp.keyWindow === window)
        else { return event }
        close()
        return nil
    }

    /// Another of Omelette's windows turned key: Dashboard or Settings opening from the
    /// footer, the floating window, onboarding (§ 3.1, Dismissal; ruling R7).
    @objc private func windowBecameKey(_ note: Notification) {
        guard isOpen, let key = note.object as? NSWindow else { return }
        if IslandEventRules.closesOnKeyWindow(isIsland: key === window, isChildOfIsland: isChildOfIsland(key)) {
            close()
        }
    }

    // MARK: - The resting notch

    /// Over the notched display's notch, under the island while it is open; ordered out
    /// while no notched display is attached.
    private func placeResting(_ screens: [IslandScreen]) {
        guard let notch = screens.lazy.compactMap(\.notchRect).first else {
            resting.orderOut(nil)
            return
        }
        resting.setFrame(IslandDisplayResolver.restingFrame(notch: notch), display: false)
        restingView.notchPath = IslandGeometry.restingPath(notch: notch, appliedFrame: resting.frame)
        if isOpen {
            resting.order(.below, relativeTo: window.windowNumber)
        } else {
            resting.orderFrontRegardless()
        }
    }

    /// A press on the bare notch, by mouse or VoiceOver (D1, D13). On the open island the
    /// same spot is its notch strip, which closes it through `localClick`; this runs while
    /// the island is closed or open on another display. Until P6's ears, a Debug ⌥-click
    /// opens as an ear will, without key, so F4–F5 can be checked (ruling R4).
    private func notchPressed(option: Bool) {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        handle(IslandEventRules.notchPressEntry(option: option, debugBuild: debugBuild))
    }

    // MARK: - Display changes

    private func observeDisplays() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspace.addObserver(self, selector: #selector(woke(_:)), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(woke(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )
    }

    /// A display came, went or changed mode; a lid open is one of these.
    @objc private func screensChanged(_ note: Notification) {
        replace()
    }

    /// Wake, display sleep or wake, the session back, the screen unlocked: re-placed now and
    /// a second later, since the first read of the screens after these can be stale (P0
    /// run 1: both passes kept the frames stable).
    @objc private func woke(_ note: Notification) {
        replace()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.replace()
        }
    }

    /// The resting notch follows the notch; an open island is re-resolved on its own display
    /// and closes when that display is gone (§ 3.1, Display and anchor; ruling R13).
    private func replace() {
        let screens = IslandScreen.current()
        placeResting(screens)
        guard isOpen, let entry, let placement else { return }
        // The status item as it is now: it moves with the displays, and the resolver
        // prefers it over the frame a status-item entry was clicked on.
        guard let again = IslandDisplayResolver.replacement(
            for: placement, entry: entry, screens: screens,
            statusItemFrame: statusItemWindow()?.frame,
            panelWidth: PopoverView.width, menuBarHeight: Self.menuBarHeight
        ) else {
            close()
            return
        }
        if let screen = screens.first(where: { $0.id == again.screenID }) {
            heights.setScreen(visibleHeight: Self.visibleHeight(of: screen))
        }
        if again != placement {
            place(again)
        }
        updateMouseIgnoring()
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
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Clicks in Omelette's own windows: inside, the notch strip, the status item, a child
        // window, or another Omelette window (`IslandEventRules.localClick`). `forward` keeps a
        // swallowed click swallowed; `self?.localClick(event) ?? event` would hand it back.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            IslandEventRules.forward(event, to: self?.localClick)
        }) {
            monitors.append(monitor)
        }
        // A click in another app or on the desktop is outside. The local and the global
        // monitor see different streams, so the island needs both (§ 3.1, Dismissal).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.close()
        }) {
            monitors.append(monitor)
        }
        // Esc, through a local key monitor (P0 run 1: six of six); a swallowed Esc stays
        // swallowed, so it never reaches the field or the app behind.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            IslandEventRules.forward(event, to: self?.keyDown)
        }) {
            monitors.append(monitor)
        }
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
