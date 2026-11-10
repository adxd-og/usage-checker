import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Opens and closes Omelette's window (notch-island spec 2026-10-29 § 3.1): the island grown
/// out of the notch — the camera housing, or the virtual one on a display without (spec
/// 2026-11-03) — or a plain panel under the status item on a display with neither. It
/// replaces 3.x's `NSPopover` and hosts the island's content (`PopoverView`, § 3.3). Every
/// decision is a pure rule: `IslandDisplayResolver` (which display, which window),
/// `IslandGeometry` (the shape, where a click lands), `IslandEventRules` (what an entry, a
/// click or a key does), `IslandTransition` (the open and close in time, § 3.2),
/// `IslandNavigation` and `IslandDrill` (All or a provider's page, and the move between them,
/// § 3.4). This class reads AppKit's state and the clock, and applies their answers.
@MainActor
final class IslandController: NSObject {
    private let window: IslandWindow
    private let model: IslandModel
    /// The shape's progress, apart from `model` so a frame of the motion redraws the shape and
    /// its mask, never the content.
    private let shapeModel: IslandShapeModel
    private let host: NSHostingView<IslandRootView<PopoverView>>
    /// The window's content while closed. The content leaves the window on every close and
    /// joins it on every open, as it did NSPopover's, so each open is an appearance: its
    /// `.task`s run again (hook status, the keep-awake fields' seed) and its timelines stop
    /// while closed (ruling R11).
    private let placeholder = NSView()
    /// The content's layout and height budget for the display it opens on (notch-island
    /// spec § 3.3): told the screen before each open and on every re-placement.
    private let layout: IslandLayoutModel
    /// Where the content is, All or a provider's page, and the move toward it (§ 3.4).
    private let navigation: IslandNavigationModel
    /// What the island tells its pet (§ 3.5): its phase, the display, the lock, Reduce Motion, the
    /// opens and closes for the jumps; it holds the app's one pet runtime.
    private let pet: IslandPetModel
    /// A resting pill on every island display, keyed by display id (spec 2026-11-03 § Resting pill,
    /// § Ears and hint): the black shape over its notch, physical or virtual, its ears and its own
    /// hover hint. A click on the pill or one of its ears opens the island on that display.
    private var pills: [UInt32: RestingPill] = [:]
    /// The pill whose left ear's head is riding the morph into the island; nil otherwise.
    private var morphingPillID: UInt32?
    private var restingArtObservers = Set<AnyCancellable>()
    /// Island on displays without a notch, flipped (spec 2026-11-03 § P4): a re-place point.
    private var virtualNotchObserver: AnyCancellable?
    /// The displays as the last re-place point read them (`placePills`): the reading the pills stand
    /// on. The ears, a pill's hint and its head read this, never the window list, so between re-place
    /// points the set of pills does not change (4.1.0 release review F2, F3).
    private var placedScreens: [IslandScreen] = []
    /// The ears on every island display (§ 3.6; spec 2026-11-03), keyed by display id, read on the
    /// displays the pills stand on.
    private lazy var earModel = IslandEarModel(read: { [weak self] in
        Self.readEars(screens: self?.placedScreens ?? [])
    })
    /// The open a click on an ear is making: its subject, its card, and whether the head morphs.
    private struct EarOpen {
        let subject: String?
        let reveal: PetCard?
        let morphs: Bool
    }
    private var earOpen: EarOpen?
    /// The ear's head on its way to the pet, as drawn (§ 3.6).
    private let earMorph: IslandEarMorphModel

    /// The open and close in time (§ 3.2); `frames` ticks it while something moves.
    private var transition = IslandTransition()
    private let frames: IslandFrameDriver
    /// The motion's clock, in the display link's time base.
    private let clock: () -> TimeInterval = { CACurrentMediaTime() }
    /// The last frame's time, ahead of `clock()`: opens and closes act no earlier (`eventTime()`).
    private var lastFrameTime: TimeInterval?

    /// Opening or open. A closing island counts as closed: an entry turns it around.
    var isOpen: Bool { transition.isOpen }
    /// The current open's entry and placement; nil while closed.
    private var entry: IslandEntry?
    private var placement: IslandDisplayResolver.Placement?
    /// Event monitors, installed from an open until the close's last frame: closed, the island
    /// adds no work (§ 3.8).
    private var monitors: [Any] = []
    /// A two-finger swipe right over the island goes Back (§ 3.4); one gesture at a time, fresh
    /// for every open.
    private var swipe = IslandSwipe()
    private var contentSizeObserver: AnyCancellable?
    nonisolated(unsafe) private var showPopoverObserver: (any NSObjectProtocol)?

    /// The status item's window, so a click there is left to the item's own toggle (one
    /// action, one dismissal). Set by `StatusBarController`.
    var statusItemWindow: @MainActor () -> NSWindow? = { nil }
    /// Has the status item read its visibility again, after a re-place point changed the set of pills
    /// (a space change, a click on a pill left behind): a setup whose last pill went gets the item back
    /// at once, and loses it when a pill comes back (spec 2026-11-03, review round 2; 4.1.0 release
    /// review F1). Set by `StatusBarController`.
    var updateStatusItemVisibility: @MainActor () -> Void = {}

    override init() {
        let model = IslandModel()
        let shapeModel = IslandShapeModel()
        let layout = IslandLayoutModel(petOn: { SettingsStore.shared.petEnabled })
        let navigation = IslandNavigationModel()
        let pet = IslandPetModel(keeper: PetKeeper(random: .system()), choice: SettingsStore.shared.petChoice)
        self.model = model
        self.shapeModel = shapeModel
        self.layout = layout
        self.navigation = navigation
        self.pet = pet
        self.window = IslandWindow.make()
        let earMorph = IslandEarMorphModel()
        self.earMorph = earMorph
        let host = NSHostingView(rootView: IslandRootView(
            model: model,
            shape: shapeModel,
            morph: earMorph,
            content: PopoverView(state: AppState.shared, layout: layout, navigation: navigation, pet: pet)
        ))
        self.host = host
        self.frames = IslandFrameDriver(source: DisplayLinkFrameSource(view: host))
        super.init()
        // The window keeps the frame it is given; the content never resizes it.
        host.sizingOptions = []
        frames.onFrame = { [weak self] now in
            self?.frame(now)
        }
        // A tile, a logo, "‹ All" and the providers changing take the keys' path: the clock,
        // Reduce Motion and the frames are here (plan ruling R13).
        navigation.onRequest = { [weak self] input, providers in
            _ = self?.navigate(input, providers: providers)
        }
        // The pet (§ 3.5): every snapshot from launch reaches its reset watch; at each frame it
        // reads what the user is doing on the island; Reduce Motion as it is now; a click that
        // leaves the island closes it.
        pet.keeper.watch(AppState.shared.$snapshot.map(\.services))
        pet.keeper.activity = { [weak self] in
            self?.userActivity() ?? .none
        }
        pet.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        pet.closeIsland = { [weak self] in
            self?.close()
        }
        pet.follow(SettingsStore.shared.$petChoice)
        // The manifests, events included, are read once off the main thread; the habitat is bare
        // until they are. No image is built until `prewarm`.
        PetAssetStore.shared.load()
        earModel.onChange = { [weak self] ears in
            self?.showEars(ears)
        }
        earModel.watch(Publishers.MergeMany(Self.earSignals()))
        // The head for the tips, built before any hover: when the manifests are read, the pet changes
        // or it is switched. `@Published` sends before the value lands, hence the hop.
        PetAssetStore.shared.$assets
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.warmRestingArt() }
            .store(in: &restingArtObservers)
        SettingsStore.shared.$petEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.warmRestingArt() }
            .store(in: &restingArtObservers)
        pet.onPetChange = { [weak self] in
            self?.warmRestingArt()
        }
        // The launch is a re-place point: the ears are read on its reading, then the pills placed.
        placePills(on: IslandScreen.current())
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
        // A re-place point of its own, never an ear update (4.1.0 release review F2, F3): only here
        // and at the display re-place points does the set of pills change.
        virtualNotchObserver = Self.virtualNotchSwitchSignal(SettingsStore.shared.$virtualNotchEnabled)
            .sink { [weak self] in self?.virtualNotchSwitched() }
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
        // A pill left behind by its display's island (review F4): it still opens, as the panel there,
        // and the pills catch up — a turn later, never from inside the pill's own click, whose window
        // may be the one that goes — and the status item with them (`placePills`).
        if IslandDisplayResolver.clickedPillIsStale(entry, screens: screens) {
            Task { @MainActor [weak self] in
                self?.placePills(on: IslandScreen.current())
            }
        }
        switch pet.entryVerdict(entry, isOpen: isOpen, openScreenID: placement?.screenID, entryScreenID: target?.id) {
        case .open:
            if let target { open(entry, on: target) }
        case .close:
            close()
        case .stay:
            if entry.becomesKey { makeKey() }
            // An ear on the island's own display: it stays, and still goes to the ear's subject, or
            // home for a card (plan R17).
            if let earOpen,
               let input = IslandNavigation.openInput(route: .reverse, subject: earOpen.subject, reveal: earOpen.reveal) {
                navigate(input)
            }
        }
    }

    /// At launch: the first one after an update that took the status item away opens the island
    /// once (`StatusItemVisibilityRules.firstLaunchAfterUpdate`). As an ear opens it, so the app
    /// in front keeps the keyboard, a beat in as the tour does, once the stored numbers have landed.
    func openIfTheUpdateTookTheItem() {
        let settings = SettingsStore.shared
        let verdict = StatusItemVisibilityRules.firstLaunchAfterUpdate(
            alreadyMarked: settings.hasOpenedIslandAfterUpdate,
            hasSeenOnboarding: settings.hasSeenOnboarding,
            setting: settings.showInMenuBar,
            islandDisplayAttached: StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.current())
        )
        guard verdict != .nothing else { return }
        settings.hasOpenedIslandAfterUpdate = true
        guard verdict == .openIsland else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            // The display that carries the island by then: one may have come or gone in the beat.
            guard let id = IslandDisplayResolver.primaryIslandScreen(IslandScreen.current())?.id else { return }
            self?.handle(.ear(displayID: id))
        }
    }

    /// Closes the island with its motion (§ 3.2): the content fades out, then the shape
    /// shrinks back into the notch; the panel fades out; Reduce Motion cross-fades. Nothing
    /// when it is closed or already closing.
    func close() {
        let now = eventTime()
        settle(at: now)
        guard isOpen, let placement else { return }
        // A jump started before this close can no longer close the island (Codex review 3).
        pet.islandClosed()
        navigation.islandClosed()
        // From the first frame of a close the whole window ignores the mouse until the next
        // open (P0 run 1: a still pointer reached the shrinking island at p = 0.285).
        window.ignoresMouseEvents = true
        transition.close(style: style(for: placement.kind), at: now)
        apply(at: now)
        frames.start()
    }

    /// The close's last frame, a move to another display, or a display that vanished: the
    /// window leaves the screen and the content leaves the window (P1 ruling R11), at once.
    private func finishClose() {
        // Whether the island holds the keyboard, read before it leaves the screen.
        let islandWasKey = window.isKeyWindow
        frames.stop()
        earMorph.stop()
        releaseMorphHead()
        transition.reset()
        window.ignoresMouseEvents = true
        removeMonitors()
        window.orderOut(nil)
        pet.setWindowVisible(false)
        window.contentView = placeholder
        shapeModel.progress = 0
        model.stage = transition.stage
        pet.show(phase: transition.phase)
        entry = nil
        placement = nil
        handBackKeyboard(islandWasKey: islandWasKey)
    }

    /// The close's keyboard (`IslandTransition.handsBackAfterClose`), a turn later: `open` calls
    /// `finishClose` on its way to a reopen, and that open decides for itself.
    private func handBackKeyboard(islandWasKey: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handsBack = IslandTransition.handsBackAfterClose(
                islandWasKey: islandWasKey,
                reopened: self.transition.phase != .closed,
                appIsActive: NSApp.isActive,
                otherWindowCanTakeKey: NSApp.windows.contains { other in
                    other !== self.window && other !== self.statusItemWindow()
                        && other.isVisible && other.canBecomeKey && !self.isChildOfIsland(other)
                }
            )
            if handsBack { NSApp.deactivate() }
        }
    }

    /// Opens on `screen` the way `IslandTransition.route` says: from closed, placed and grown
    /// out of the notch; while closing on the same display, turned around from where it is
    /// (§ 3.2, Interrupt); open or closing elsewhere, closed at once and opened afresh there,
    /// since one window cannot move in two places.
    private func open(_ entry: IslandEntry, on screen: IslandScreen) {
        let now = eventTime()
        // Whether the island holds the keyboard, read before anything below orders it out.
        let islandWasKey = window.isKeyWindow
        // Deadlines due by now first, as a frame would have applied them: a close may have ended.
        settle(at: now)
        // Clicked or not, the hint ends where the island begins.
        endHint()
        let route = IslandTransition.route(phase: transition.phase, sameDisplay: placement?.screenID == screen.id)
        if route == .moveAndOpen {
            navigation.islandClosed()
            finishClose()
        }
        AppState.shared.refreshForPopover()
        // Same moment, same reasoning as the refresh: the user is looking at the app, so this
        // is when an update is worth noticing. Throttled to once an hour inside the updater.
        Updater.shared.checkInBackgroundIfDue()
        // The screen it opens on, handed in before the content appears, so its first layout
        // already has its width and its budget (§ 3.3).
        layout.place(on: screen, visibleHeight: Self.visibleHeight(of: screen))
        self.entry = entry
        // Every open starts at All, or at the only provider's page; nothing is kept from the last
        // open (§ 3.4; owner 2026-10-30). An open that turns around a close still running on this
        // display is an interrupted close, not an open: the content never left and keeps its page
        // (plan ruling R4). Before the content lays out, so its first layout is already home.
        if let input = IslandNavigation.openInput(route: route, subject: earOpen?.subject, reveal: earOpen?.reveal) {
            navigation.apply(
                input, providers: AppState.shared.snapshot.services.map(\.id),
                reduceMotion: false, at: now
            )
        }
        if route != .reverse {
            // The shown status item, whatever opened the island: the panel hangs under it
            // when it is on this display (ruling R8).
            place(IslandDisplayResolver.placement(
                on: screen, entry: entry, statusItemFrame: statusItemWindow()?.frame,
                panelWidth: IslandPresentationRules.width(screenWidth: screen.frame.width), menuBarHeight: Self.menuBarHeight
            ))
            // The content joins the window and lays out at the closed stage first, so every
            // fade has a rendered start, the first open after launch included.
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }
        guard let placement else { return }
        if route != .reverse {
            startEarMorph(on: screen, placement: placement, at: now)
        }
        // Every open, a turned-around close included, starts a new generation of jumps.
        pet.islandOpened()
        // On screen from here until `finishClose`. Not the window's occlusion state: measured on
        // the island, it reports "not visible" a moment after every open, though nothing can
        // cover a window at this level (owner 2026-10-30, the pet stood still).
        pet.setWindowVisible(true)
        transition.open(style: style(for: placement.kind), at: now)
        apply(at: now)
        switch IslandTransition.keyAction(entryBecomesKey: entry.becomesKey, islandIsKey: islandWasKey) {
        case .makeKey:
            makeKey()
        case .orderFront:
            window.orderFrontRegardless()
        case .handBack:
            window.orderFrontRegardless()
            // `resignKey()` is AppKit's own to call, and ordering the window out and back would
            // leave Omelette active with no key window, typing going nowhere. The island turned
            // key by making Omelette active (`makeKey`), so the inverse is deactivating it: the
            // app that was active before gets the keyboard back, and the island stays up, since
            // it does not hide on deactivation.
            NSApp.deactivate()
        }
        if route != .reverse {
            installMonitors()
        }
        updateMouseIgnoring()
        frames.start()
    }

    /// Opened by a click: key, with the content as first responder, so typing, Tab, paste,
    /// ⌘A and Esc reach the island and never the app behind (§ 3.1, Focus). P0: works with
    /// Safari, iTerm2 or Finder in front; the island turning key makes Omelette active.
    private func makeKey() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
    }

    // MARK: - Navigation

    /// Applies a navigation input (§ 3.4) at the motion's clock, with Reduce Motion as it is
    /// now, over the providers on screen (`providers`, or the app's own list): a move starts the
    /// frames that draw it, or just lands while closed, and Esc at All closes. Returns the reducer's
    /// action.
    @discardableResult
    private func navigate(_ input: IslandNavigation.Input, providers: [String]? = nil) -> IslandNavigation.Action {
        let now = eventTime()
        let action = navigation.apply(
            input,
            providers: providers ?? AppState.shared.snapshot.services.map(\.id),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            at: now
        )
        switch action {
        case .go:
            if IslandTransition.pageMoveWantsFrames(phase: transition.phase) { frames.start() }
        case .close:
            close()
        case .stay, .pass:
            break
        }
        return action
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
            return .island(geometry.region(of: point, contentSize: model.contentSize, progress: shapeModel.progress))
        }
        if pills.values.contains(where: { $0.panel === target }) { return .restingNotch }
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

    /// The island's keys while it is the key window (§ 3.4): Esc goes back from a page and
    /// closes at All; ⌘0 is All, ⌘1–⌘9 the providers on screen. `IslandEventRules.keyRoute`
    /// decides: a navigation key is the island's in every phase — applied while open, swallowed
    /// while it closes — so none ever reaches a field or the app behind, or beeps, a ⌘ digit with
    /// no provider behind it included (owner 2026-10-30; Codex review finding 2). A key help
    /// popover takes its own Esc. Any other key aimed at a closing island goes nowhere unless it
    /// carries ⌘ (`swallowsKey`), so ⌘Q still quits.
    private func keyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        let key = IslandEventRules.navigationKey(
            keyCode: event.keyCode,
            command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control),
            keyWindowIsIsland: NSApp.keyWindow === window
        )
        let closingSwallows = transition.swallowsKey(
            inIsland: event.window === window, command: flags.contains(.command)
        )
        switch IslandEventRules.keyRoute(key, isOpen: isOpen, closingSwallows: closingSwallows) {
        case .navigate(let input):
            navigate(input)
            return nil
        case .swallow:
            return nil
        case .pass:
            return event
        }
    }

    /// Every scroll while the island is open feeds the swipe, with whether the pointer is inside
    /// the island's drawn shape; a swipe right that began inside and stayed there goes Back
    /// (`IslandSwipe`, plan ruling R12, Codex review finding 5). The scroll itself always goes on,
    /// so the agents list and an expanded detail still scroll.
    private func scrolled(_ event: NSEvent) -> NSEvent? {
        guard isOpen else { return event }
        let swiped = swipe.feed(
            phase: IslandSwipe.phase(gesture: event.phase, momentum: event.momentumPhase),
            fingerDeltaX: IslandSwipe.fingerDeltaX(
                scrollingDeltaX: event.scrollingDeltaX, invertedFromDevice: event.isDirectionInvertedFromDevice
            ),
            deltaY: event.scrollingDeltaY,
            inside: isInsideShape(event)
        )
        if swiped {
            navigate(.back)
        }
        return event
    }

    /// The event lands on the island's shape as it is drawn now (`IslandGeometry.region`), not on
    /// its window's transparent rest (the window is larger than the shape) nor another window.
    private func isInsideShape(_ event: NSEvent) -> Bool {
        guard event.window === window, let geometry = model.geometry else { return false }
        let point = IslandGeometry.windowPoint(
            screenPoint: window.convertPoint(toScreen: event.locationInWindow),
            windowFrame: window.frame
        )
        return geometry.region(of: point, contentSize: model.contentSize, progress: shapeModel.progress) != .outside
    }

    /// Another of Omelette's windows turned key: Dashboard or Settings opening from the
    /// footer, the floating window, onboarding (§ 3.1, Dismissal; ruling R7).
    @objc private func windowBecameKey(_ note: Notification) {
        guard isOpen, let key = note.object as? NSWindow else { return }
        if IslandEventRules.closesOnKeyWindow(isIsland: key === window, isChildOfIsland: isChildOfIsland(key)) {
            close()
        }
    }

    // MARK: - The resting pills

    /// A re-place point (launch, a display change, wake or unlock, a space change that moved the set,
    /// a click on a pill left behind, Island on displays without a notch flipped) with its reading of
    /// the displays: kept as the reading the pills stand on, handed to `IslandDisplayPresence` for the
    /// views that word themselves on it (spec 2026-11-10 § A), the ears read on it, the pills made,
    /// dropped and laid over it. Only here does the set of pills change, and a changed set has the
    /// status item read its visibility again (4.1.0 release review F1): the last pill going (a
    /// full-screen space on a lone notchless display) forces the item on, and a pill coming back hides
    /// it again.
    private func placePills(on screens: [IslandScreen]) {
        placedScreens = screens
        // Every placement, before anything below can return: Settings and onboarding have no other
        // source for whether a display shows the island.
        IslandDisplayPresence.shared.placed(on: screens)
        var setChanged = false
        earModel.displaysChanged {
            setChanged = !placeResting(screens).isEmpty
        }
        if setChanged { updateStatusItemVisibility() }
    }

    /// A pill over every island display's notch, physical or virtual, with that display's ears,
    /// under the island while it is open (spec 2026-11-03 § Resting pill, § Ears and hint); made for
    /// a display that gains an island, dropped for one that loses it or goes away. `placePills`'s.
    private func placeResting(_ screens: [IslandScreen]) -> RestingPillRules.Changes {
        let wanted = RestingPillRules.pills(screens)
        let changes = RestingPillRules.changes(kept: Set(pills.keys), wanted: wanted)
        for id in changes.drop {
            if morphingPillID == id { morphingPillID = nil }
            pills.removeValue(forKey: id)?.close()
        }
        for id in changes.create {
            let pill = makePill(id)
            pill.show(earModel.ears[id] ?? .none)
            pills[id] = pill
        }
        for wanted in wanted {
            guard let pill = pills[wanted.displayID] else { continue }
            place(pill, over: wanted.notch)
        }
        // A new pill's head and tips, at its own display's scale, once it stands on that display.
        if !changes.create.isEmpty { warmRestingArt() }
        return changes
    }

    /// The pills there are, each over its notch in the reading it was placed from, with its ears as
    /// they are now: an ear update never makes or drops one (`RestingPillRules.relaid`).
    private func layOutPills() {
        for wanted in RestingPillRules.relaid(kept: Set(pills.keys), screens: placedScreens) {
            guard let pill = pills[wanted.displayID] else { continue }
            place(pill, over: wanted.notch)
        }
    }

    /// A new display's pill: its click and its ears open the island on that display; its tracking
    /// area drives its own hint.
    private func makePill(_ id: UInt32) -> RestingPill {
        let pill = RestingPill(displayID: id)
        pill.notchView.onPress = { [weak self] in
            self?.handle(.notch(displayID: id))
        }
        pill.notchView.onHover = { [weak self] inside in
            self?.notchHovered(inside, on: id)
        }
        pill.hintFrames.onFrame = { [weak self] now in
            self?.hintFrame(now, on: id)
        }
        pill.leftEarView.onPress = { [weak self] in
            self?.leftEarPressed(on: id)
        }
        pill.rightEarView.onPress = { [weak self] in
            self?.rightEarPressed(on: id)
        }
        return pill
    }

    /// `pill` over `notch` with its display's ears, holding the hint's room while its hint shows.
    private func place(_ pill: RestingPill, over notch: CGRect) {
        pill.room = !pill.hint.isAtRest
        let ears = earModel.ears[pill.displayID] ?? .none
        let left = ears.left != nil
        let right = ears.right != nil
        pill.panel.setFrame(
            RestingLayout.frame(notch: notch, left: left, right: right, hintRoom: pill.room), display: false
        )
        pill.notchView.layout = RestingLayout(notch: notch, left: left, right: right, appliedFrame: pill.panel.frame)
        pill.placeEars()
        if transition.phase != .closed {
            pill.panel.order(.below, relativeTo: window.windowNumber)
        } else {
            pill.panel.orderFrontRegardless()
        }
    }

    // MARK: - The notch hint (§ 3.1, D13; spec 2026-11-03: on the hovered pill only)

    /// A pill's tracking area's report. One wait per arrival, cancelled by a leave: no timer otherwise.
    private func notchHovered(_ inside: Bool, on id: UInt32) {
        guard let pill = pills[id] else { return }
        if inside {
            guard pill.hint.pointerEntered() else { return }
            pill.hintDelay?.cancel()
            pill.hintDelay = Task { @MainActor [weak self] in
                guard (try? await Task.sleep(for: .seconds(IslandMotion.hintDelay))) != nil else { return }
                self?.hintDelayElapsed(on: id)
            }
        } else {
            pill.hintDelay?.cancel()
            pill.hintDelay = nil
            let now = hintEventTime(pill)
            pill.hint.pointerLeft(at: now)
            showHint(pill, at: now)
        }
    }

    private func hintDelayElapsed(on id: UInt32) {
        guard let pill = pills[id] else { return }
        pill.hintDelay = nil
        let now = hintEventTime(pill)
        pill.hint.delayElapsed(
            at: now, islandClosed: transition.phase == .closed,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        showHint(pill, at: now)
    }

    /// One frame of a pill's spring.
    private func hintFrame(_ now: TimeInterval, on id: UInt32) {
        guard let pill = pills[id] else { return }
        pill.lastHintFrameTime = now
        pill.hint.advance(to: now)
        showHint(pill, at: now)
    }

    /// A pill's hint as it is now, on screen: frames only while its spring moves, and its window's
    /// room only while something shows.
    private func showHint(_ pill: RestingPill, at now: TimeInterval) {
        pill.notchView.look = pill.hint.look(at: now)
        pill.placeEars()
        pill.notchView.tracksHint = pill.hint.isUp
        if pill.hint.needsFrames {
            pill.hintFrames.start()
        } else {
            pill.hintFrames.stop()
        }
        if pill.room == pill.hint.isAtRest,
           let notch = placedScreens.first(where: { $0.id == pill.displayID })?.islandNotch {
            place(pill, over: notch)
        }
    }

    /// The island is opening, or the displays changed: every pill's hint ends.
    private func endHint() {
        for pill in pills.values {
            pill.hintDelay?.cancel()
            pill.hintDelay = nil
            pill.hint.end()
            showHint(pill, at: hintEventTime(pill))
        }
    }

    private func hintEventTime(_ pill: RestingPill) -> TimeInterval {
        IslandFrameDriver.eventTime(now: clock(), lastFrame: pill.lastHintFrameTime)
    }

    /// Builds the chosen pet's head off the main thread at each pill's scale — its notch's height on
    /// its display reading's backing scale, the same input `IslandEarRules.headFits` reads (Task 2) —
    /// and hands it to that pill. Pet off: the shape only (D13), and the ear's neutral dot needs no
    /// image.
    private func warmRestingArt() {
        guard SettingsStore.shared.petEnabled,
              let assets = PetAssetStore.shared.assets,
              let shown = pet.shown(in: assets.library),
              let manifest = assets.library.manifests[shown.animal]
        else {
            for pill in pills.values { pill.showArt(nil, tips: nil) }
            return
        }
        let screens = placedScreens
        let sprites = assets.sprites
        for pill in pills.values {
            guard let screen = screens.first(where: { $0.id == pill.displayID }), let notch = screen.islandNotch
            else { continue }
            let scale = IslandEarRules.headScale(earHeight: notch.height, backingScale: screen.backingScale)
            let key = PetSpriteCache.Key(
                animal: shown.animal, palette: shown.palette, sprite: .ear, pixelsPerBead: scale.pixelsPerBead
            )
            let tips = PetEarTips.tips(of: manifest.ear, band: IslandMotion.hintDown, scale: scale)
            Task { [weak self, weak pill] in
                await Task.detached(priority: .utility) {
                    sprites.prewarmEar(animal: key.animal, palette: key.palette, pixelsPerBead: key.pixelsPerBead)
                }.value
                // A newer pet's own warm-up answers for that pet, and Pet off has already cleared the art.
                guard let self, let pill,
                      PetEarTips.stillWanted(
                          builtFor: shown, shownNow: self.pet.shown(in: assets.library),
                          petOn: SettingsStore.shared.petEnabled
                      )
                else { return }
                pill.showArt(sprites.cachedImage(key).map { RestingHead(image: $0, scale: scale) }, tips: tips)
            }
        }
    }

    // MARK: - The ears (§ 3.6)

    /// The ears on every island display of `screens`, the reading the pills stand on, from the app's
    /// state as it is now.
    private static func readEars(screens: [IslandScreen]) -> [UInt32: IslandEars] {
        let settings = SettingsStore.shared
        return IslandEarRules.earsByDisplay(
            mood: PetMoodInput(
                sessions: AgentSessionStore.shared.sessions,
                services: AppState.shared.snapshot.services,
                enabledIDs: AppState.shared.switchedOnIDs,
                claudeBinaryFound: ClaudeSignInModel.shared.binaryFound,
                keepAwake: KeepAwakeModel.shared.state
            ),
            mode: settings.percentMode,
            petOn: settings.petEnabled,
            earsOn: settings.earsEnabled,
            showInMenuBar: settings.showInMenuBar,
            screens: screens,
            now: Date(), calendar: .current, locale: .current
        )
    }

    /// Every state the ears are read from (plan R12); the displays come through `replace`. No timer:
    /// keep awake's end arrives through its model's own deadline poll.
    private static func earSignals() -> [AnyPublisher<Void, Never>] {
        let settings = SettingsStore.shared
        return [
            AgentSessionStore.shared.$sessions.map { _ in () }.eraseToAnyPublisher(),
            AppState.shared.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            AppState.shared.$polledIDs.map { _ in () }.eraseToAnyPublisher(),
            ClaudeSignInModel.shared.$binary.map { _ in () }.eraseToAnyPublisher(),
            ClaudeSignInModel.shared.$hasLookedForBinary.map { _ in () }.eraseToAnyPublisher(),
            KeepAwakeModel.shared.$state.map { _ in () }.eraseToAnyPublisher(),
            settings.$showsRemaining.map { _ in () }.eraseToAnyPublisher(),
            settings.$petEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$earsEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$showInMenuBar.map { _ in () }.eraseToAnyPublisher(),
            // A provider's switch is `@AppStorage`, which publishes nothing (`SettingsPage`): a
            // defaults write is its signal, so off means off with a poll still running.
            defaultsWriteSignal(),
        ]
    }

    /// The notification comes on the writing thread (keep awake's Apply, Sparkle), and the `map`
    /// below is main-actor code: the hop comes first, as in `SettingsPage`.
    static func defaultsWriteSignal(center: NotificationCenter = .default) -> AnyPublisher<Void, Never> {
        center.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in () }.eraseToAnyPublisher()
    }

    /// The ears moved: each pill redraws them and is laid out again where it stands, never made or
    /// dropped, with no window list read (4.1.0 release review F2, F3).
    private func showEars(_ ears: [UInt32: IslandEars]) {
        for (id, pill) in pills {
            pill.show(ears[id] ?? .none)
        }
        layOutPills()
    }

    /// The ear as it is at the click, never as it was drawn (plan R15), on the display it is on: the
    /// island opens there (spec 2026-11-03 § Ears and hint).
    private func leftEarPressed(on id: UInt32) {
        guard let ear = earModel.ears[id]?.left else { return }
        earPressed(ear.action, morphs: ear.mark == .head, on: id)
    }

    private func rightEarPressed(on id: UInt32) {
        guard let ear = earModel.ears[id]?.right else { return }
        earPressed(ear.action, morphs: false, on: id)
    }

    /// `displayID`: the ear's display, kept for a jump's late fallback too (spec 2026-11-03 § Opening).
    private func earPressed(_ action: IslandEarAction, morphs: Bool, on displayID: UInt32) {
        switch action {
        case .jump(let id):
            // A failed jump would be silent with no row on screen (plan R6).
            guard let session = AgentSessionStore.shared.sessions.first(where: { $0.id == id }) else {
                openFromEar(on: displayID, subject: nil, reveal: .agents, morphs: false)
                return
            }
            SessionActivator.jump(to: session, landed: pet.earJumpStarted(orElse: { [weak self] in
                self?.openFromEar(on: displayID, subject: nil, reveal: .agents, morphs: false)
            }))
        case .open(let subject, let reveal):
            openFromEar(on: displayID, subject: subject, reveal: reveal, morphs: morphs)
        }
    }

    /// The island at the ear's subject on the ear's display, not key until the user clicks inside
    /// (§ 3.1, Focus). The card is asked for once the content has joined the window.
    private func openFromEar(on displayID: UInt32, subject: String?, reveal: PetCard?, morphs: Bool) {
        earOpen = EarOpen(subject: subject, reveal: reveal, morphs: morphs)
        handle(.ear(displayID: displayID))
        earOpen = nil
        // With its display gone nothing opened, and a request left waiting would surface at the next open.
        if isOpen { navigation.ask(toShow: reveal) }
    }

    /// The head sets off from the left ear toward the pet's place, where the presentation has a
    /// habitat and the column has been measured (§ 3.6; plan R7, R8). The ear's own head hides
    /// until the island has grown over it.
    private func startEarMorph(on screen: IslandScreen, placement: IslandDisplayResolver.Placement, at now: TimeInterval) {
        let settings = SettingsStore.shared
        let eligible = IslandPresentationRules.presentation(
            notchPresent: placement.kind == .island, screenWidth: screen.frame.width,
            petOn: settings.petEnabled, earsOn: settings.earsEnabled
        ).morphEligible
        guard earOpen?.morphs == true,
              let pill = pills[placement.screenID],
              IslandEarMorph.eligible(
                  mark: earModel.ears[placement.screenID]?.left?.mark, morphEligible: eligible,
                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
              ),
              let head = pill.head, let geometry = model.geometry,
              let target = IslandEarMorph.target(
                  contentOrigin: geometry.contentOrigin(contentSize: model.contentSize),
                  columnHeight: layout.rightColumnViewport,
                  xBeads: pet.keeper.runtime.xBeads,
                  scale: PetHabitatRules.scale(petBeads: PetContract.size, backingScale: window.backingScaleFactor)
              )
        else { return }
        // The ear's head as drawn, from its pill's window into the island's.
        let drawn = IslandEarRules.headRect(in: pill.leftEarView.frame, scale: head.scale)
        let from = IslandGeometry.local(IslandGeometry.global(drawn, in: pill.panel.frame), in: window.frame)
        earMorph.start(
            IslandEarMorph(start: now, from: from, to: target),
            image: head.image, backingScale: head.scale.backingScale
        )
        pill.leftEarView.hidesHead = true
        morphingPillID = pill.displayID
    }

    /// The morph is over or cut short: the head shows in its ear again.
    private func releaseMorphHead() {
        if let id = morphingPillID { pills[id]?.leftEarView.hidesHead = false }
        morphingPillID = nil
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
        // A full-screen space can hide its display's menu bar, and the pill with it (spec 2026-11-03
        // § Hidden menu bar). Lighter than a wake: only a changed set of island displays moves anything.
        workspace.addObserver(
            self, selector: #selector(spaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        // The motion's frames pause while the displays sleep and stop for good if the island's
        // window ever closes (it is normally only ordered out). Any wake signal resumes them:
        // a missed screensDidWake must not leave a pending motion frozen.
        workspace.addObserver(
            self, selector: #selector(displaysSlept(_:)),
            name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        for name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspace.addObserver(self, selector: #selector(displaysWoke(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(islandWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(woke(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )
        // The pet holds still behind the lock screen and under Reduce Motion (§ 3.5, Animate only
        // when), from the moment either changes.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )
        workspace.addObserver(
            self, selector: #selector(displayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    /// The displays went to sleep: no frames until they wake (§ 3.8).
    @objc private func displaysSlept(_ note: Notification) {
        frames.displaysSlept()
        for pill in pills.values { pill.hintFrames.displaysSlept() }
        pet.setDisplayAwake(false)
    }

    /// The displays woke: frames resume only if the motion is still pending; its first frame
    /// settles every deadline that passed meanwhile.
    @objc private func displaysWoke(_ note: Notification) {
        frames.displaysWoke()
        for pill in pills.values { pill.hintFrames.displaysWoke() }
        pet.setDisplayAwake(true)
    }

    /// The island's window closing for good: no more frames.
    @objc private func islandWillClose(_ note: Notification) {
        frames.stop()
    }

    /// The screen locked or unlocked: the pet's gate (§ 3.5).
    @objc private func screenLocked(_ note: Notification) {
        pet.setScreenLocked(true)
    }

    @objc private func screenUnlocked(_ note: Notification) {
        pet.setScreenLocked(false)
    }

    /// Reduce Motion switched in System Settings: the pet's gate (§ 3.5).
    @objc private func displayOptionsChanged(_ note: Notification) {
        pet.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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

    /// Another space (review F6): now and a second later, since the first read after a switch can be
    /// stale as after a wake, but only the pills, and only when the set of displays that carry an
    /// island changed — a full-screen space whose menu bar window goes away (`MenuBarWindowRules`),
    /// or the way back. The notched Mac alone, or any switch that leaves every menu bar where it was, does
    /// nothing: no hint cut, no ear re-read, no open island re-resolved.
    @objc private func spaceChanged(_ note: Notification) {
        placePillsIfTheirSetChanged()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.placePillsIfTheirSetChanged()
        }
    }

    /// A changed set reads the ears (a pill that comes back needs its display's) and places the
    /// pills, and the status item follows; a hint on a pill that stays keeps going, and an open island
    /// stays as it is. An unchanged set keeps the reading the pills stand on.
    private func placePillsIfTheirSetChanged() {
        let screens = IslandScreen.current()
        guard !RestingPillRules.changes(kept: Set(pills.keys), wanted: RestingPillRules.pills(screens)).isEmpty
        else { return }
        placePills(on: screens)
    }

    /// Island on displays without a notch was flipped (spec 2026-11-03 § P4): re-placed as a display
    /// change is (`replace`), on a reading that carries the new value — pills made or dropped, the ears
    /// read on it, an open island re-resolved on its display, the panel there once its virtual notch is
    /// gone — and the status item reads its visibility again, whether or not the set of pills moved.
    private func virtualNotchSwitched() {
        replace()
        updateStatusItemVisibility()
    }

    /// When the switch's flip re-places: each change of `setting` once, never the value sent at
    /// subscription (the launch has placed on it) nor a write of the same value; a turn of the main
    /// queue later, since `@Published` sends before the value lands and the reading reads the store.
    static func virtualNotchSwitchSignal<P: Publisher>(_ setting: P) -> AnyPublisher<Void, Never>
    where P.Output == Bool, P.Failure == Never {
        setting
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// The resting pills follow the displays' notches, physical or virtual; an open island is
    /// re-resolved on its own display and closes when that display is gone (§ 3.1, Display and
    /// anchor; ruling R13; spec 2026-11-03).
    private func replace() {
        endHint()
        let screens = IslandScreen.current()
        // A lid open or a display gaining an island changes no other state, so nothing else would
        // read the ears (plan R18).
        placePills(on: screens)
        // After the pills stand on their displays: each head is built at its own display's scale (R9).
        warmRestingArt()
        guard transition.phase != .closed, let entry, let placement else { return }
        // The status item as it is now: it moves with the displays, and the resolver
        // prefers it over the frame a status-item entry was clicked on.
        guard let again = IslandDisplayResolver.replacement(
            for: placement, entry: entry, screens: screens,
            statusItemFrame: statusItemWindow()?.frame,
            panelWidth: Self.panelWidth(on: placement.screenID, in: screens), menuBarHeight: Self.menuBarHeight
        ) else {
            // Its display is gone: nothing left to animate on.
            navigation.islandClosed()
            finishClose()
            return
        }
        // A closing island finishes where it is.
        guard isOpen else { return }
        if let screen = screens.first(where: { $0.id == again.screenID }) {
            layout.place(on: screen, visibleHeight: Self.visibleHeight(of: screen))
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

    /// The panel's width on the display with `id`: the island's rule, so the two lay their
    /// content out alike (§ 3.9). The island's own comes from the resolver.
    private static func panelWidth(on id: UInt32, in screens: [IslandScreen]) -> CGFloat {
        IslandPresentationRules.width(screenWidth: screens.first { $0.id == id }?.frame.width ?? 0)
    }

    /// The visible height `IslandLayoutModel.place` takes for `screen`: the panel's budget
    /// comes from it (plan ruling R7); the island budgets from its own window instead.
    private static func visibleHeight(of screen: IslandScreen) -> CGFloat {
        PopoverHeightRules.screenVisibleHeight(
            frameMaxY: screen.frame.maxY,
            visibleFrameMaxY: screen.visibleFrame.maxY,
            visibleFrameHeight: screen.visibleFrame.height,
            menuBarHeight: menuBarHeight
        )
    }

    // MARK: - Motion

    /// Brings the transition up to `now`, as a frame would: every deadline due by then is
    /// applied and shown, and a close that has ended finishes. Every open and close starts
    /// here, so what they act on never depends on whether a frame came first.
    private func settle(at now: TimeInterval) {
        guard transition.phase != .closed else { return }
        transition.advance(to: now)
        apply(at: now)
        if transition.phase == .closed {
            finishClose()
        }
    }

    /// The time an open or a close acts at: now, but never behind the last drawn frame.
    private func eventTime() -> TimeInterval {
        IslandFrameDriver.eventTime(now: clock(), lastFrame: lastFrameTime)
    }

    /// One frame of the frame source: the transition and the page move (§ 3.2, Drill-down) at
    /// the frame's time, handed to the views; the mouse re-checked against the shape as it
    /// moves (P0 strategy B); the window ordered out on the close's last frame; the frames
    /// stopped once nothing moves.
    private func frame(_ now: TimeInterval) {
        lastFrameTime = now
        settle(at: now)
        guard transition.phase != .closed else { return }
        navigation.advance(to: now)
        if !earMorph.advance(to: now) {
            releaseMorphHead()
        }
        updateMouseIgnoring()
        if !transition.needsFrames, !navigation.isMoving {
            frames.stop()
        }
    }

    /// The shape's progress on every call, the stage only when it changed, so the content's
    /// views are re-evaluated a handful of times per open, never per frame.
    private func apply(at now: TimeInterval) {
        let progress = transition.progress(at: now)
        if shapeModel.progress != progress {
            shapeModel.progress = progress
        }
        if model.stage != transition.stage {
            model.stage = transition.stage
        }
        // The pet animates only while the island is open (§ 3.5): its clock stops on a close's
        // first frame. The model acts on a change only.
        pet.show(phase: transition.phase)
    }

    /// Read at every open and close, so a Reduce Motion switch applies to the next one.
    private func style(for kind: IslandDisplayResolver.Kind) -> IslandMotion.Style {
        IslandMotion.style(kind: kind, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: - The pet

    /// What the user is doing on the island, read by the pet at each frame (§ 3.5 Runtime: no bit
    /// while the pointer is over the right column or a field has focus): the pointer in the
    /// content's coordinates, and the field editor as the window's first responder.
    private func userActivity() -> PetUserActivity {
        var activity = PetUserActivity.none
        if let geometry = model.geometry {
            let point = IslandGeometry.windowPoint(screenPoint: NSEvent.mouseLocation, windowFrame: window.frame)
            let origin = geometry.contentOrigin(contentSize: model.contentSize)
            activity.pointerOverContent = PetHabitatRules.pointerOverContent(
                CGPoint(x: point.x - origin.x, y: point.y - origin.y), contentSize: model.contentSize
            )
        }
        activity.fieldFocused = window.firstResponder is NSText
        return activity
    }

    // MARK: - Clicks through the transparent part

    /// The window takes the mouse only while the pointer is inside the shape as it is drawn
    /// now, checked on every mouse move, every frame of the motion and every content-size
    /// change (P0 run 1, strategy B: 0 misses). Closing, the window ignores the mouse
    /// whatever the shape (`close()`).
    private func updateMouseIgnoring(contentSize: CGSize? = nil) {
        guard isOpen, let geometry = model.geometry else { return }
        let point = IslandGeometry.windowPoint(screenPoint: NSEvent.mouseLocation, windowFrame: window.frame)
        let region = geometry.region(
            of: point, contentSize: contentSize ?? model.contentSize, progress: shapeModel.progress
        )
        let inside = region != .outside
        if window.ignoresMouseEvents == inside {
            window.ignoresMouseEvents = !inside
        }
    }

    private func installMonitors() {
        removeMonitors()
        swipe = IslandSwipe()
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
            guard let self else { return }
            let frame = self.statusItemWindow()?.frame
            if IslandEventRules.globalClick(at: NSEvent.mouseLocation, statusItemFrame: frame) != .pass { self.close() }
        }) {
            monitors.append(monitor)
        }
        // Esc and ⌘ digits, through a local key monitor (P0 run 1: six of six); a swallowed key
        // stays swallowed, so it never reaches the field or the app behind.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            IslandEventRules.forward(event, to: self?.keyDown)
        }) {
            monitors.append(monitor)
        }
        // Two fingers across the island: a swipe right goes Back; the scroll goes on either way.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            IslandEventRules.forward(event, to: self?.scrolled)
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
