import CoreGraphics

/// Where an open of the island came from (notch-island spec 2026-10-29 § 3.1, Entry points).
enum IslandEntry: Equatable, Sendable {
    /// A click on the status item, with its button's window frame in global coordinates.
    case statusItem(buttonFrame: CGRect)
    /// A click on the notch itself (the resting notch panel).
    case notch
    /// A click on an ear (P6; in P1 a Debug-only ⌥-click on the notch, plan ruling R4).
    case ear
    /// The `.showPopover` route, with the pointer where it was.
    case notification(pointer: CGPoint)

    /// Opened by a click, the island becomes key; opened from an ear it does not until the
    /// user clicks inside it (§ 3.1, Focus).
    var becomesKey: Bool {
        if case .ear = self { return false }
        return true
    }
}

/// Which display the island opens on, island or panel, and the window it opens in
/// (notch-island spec 2026-10-29 § 3.1, Display and anchor; § 3.9). Pure: the controller
/// reads the screens, the status item and the pointer, and applies the answer.
enum IslandDisplayResolver {
    enum Kind: Equatable, Sendable {
        /// Grown out of the notch, centred on it.
        case island
        /// A plain panel under the status item, on a display without a notch.
        case panel
    }

    struct Placement: Equatable, Sendable {
        let kind: Kind
        let screenID: UInt32
        /// The window: fixed while open, the shape is drawn inside it. Global coordinates,
        /// whole points.
        let windowFrame: CGRect
        /// The global x the body centres on: the notch's centre, the status item's, or the
        /// visible frame's.
        let anchorMidX: CGFloat
        /// The notch in global coordinates; nil for the panel.
        let notch: CGRect?
        /// The body's width: the island's from `IslandPresentationRules`, the panel's as
        /// handed in (the same rule, from `IslandController`).
        let bodyWidth: CGFloat
    }

    /// Room on each side of the body inside the window: P2's spring overshoot, the panel's
    /// shadow.
    static let sideMargin: CGFloat = 12
    /// The window stops this far above the Dock (§ 3.3).
    static let bottomMargin: CGFloat = 8
    /// Between the status item (or the menu bar) and the panel's top.
    static let panelGap: CGFloat = 6

    /// The status item's click → that item's display; an ear or the notch → the notched
    /// display; the notification route → the display under the pointer. The first and the
    /// last fall back to the main display, then to the first one.
    static func display(for entry: IslandEntry, screens: [IslandScreen], mainScreenID: UInt32?) -> IslandScreen? {
        switch entry {
        case .statusItem(let button):
            let centre = CGPoint(x: button.midX, y: button.midY)
            return screens.first { Self.holds($0, centre) } ?? Self.mainScreen(screens, mainScreenID)
        case .notch, .ear:
            return screens.first { $0.hasNotch }
        case .notification(let pointer):
            return screens.first { Self.holds($0, pointer) } ?? Self.mainScreen(screens, mainScreenID)
        }
    }

    /// The placement for `entry`; nil when it has no display (the notch or an ear with no
    /// notched display attached). `statusItemFrame` is the shown status item's window frame,
    /// nil while it is hidden.
    static func placement(
        for entry: IslandEntry, screens: [IslandScreen], mainScreenID: UInt32?,
        statusItemFrame: CGRect?, panelWidth: CGFloat, menuBarHeight: CGFloat
    ) -> Placement? {
        display(for: entry, screens: screens, mainScreenID: mainScreenID).map {
            Self.placement(
                on: $0, entry: entry, statusItemFrame: statusItemFrame,
                panelWidth: panelWidth, menuBarHeight: menuBarHeight
            )
        }
    }

    /// On a notched display: the island, centred on the notch, from the screen's top to
    /// 8 pt above the Dock. Elsewhere: the panel, centred under the status item whenever the
    /// item is shown on this display, whatever the entry; only without one there, under the
    /// menu bar at the visible frame's centre (ruling R8). Clamped inside the visible frame.
    /// `menuBarHeight` places a panel on a display whose menu bar hides.
    static func placement(
        on screen: IslandScreen, entry: IslandEntry, statusItemFrame: CGRect?,
        panelWidth: CGFloat, menuBarHeight: CGFloat
    ) -> Placement {
        let bottom = (screen.visibleFrame.minY + bottomMargin).rounded(.up)
        if let notch = screen.notchRect {
            let bodyWidth = IslandPresentationRules.width(screenWidth: screen.frame.width)
            let width = bodyWidth + 2 * sideMargin
            let x = clamp((notch.midX - width / 2).rounded(.down), screen.frame.minX, screen.frame.maxX - width)
            let top = screen.frame.maxY.rounded(.down)
            return Placement(
                kind: .island, screenID: screen.id,
                windowFrame: CGRect(x: x, y: bottom, width: width, height: top - bottom),
                anchorMidX: notch.midX, notch: notch, bodyWidth: bodyWidth
            )
        }
        let visible = screen.visibleFrame
        let anchorMidX: CGFloat
        let under: CGFloat
        if let button = itemFrame(entry, shown: statusItemFrame),
           holds(screen, CGPoint(x: button.midX, y: button.midY)) {
            anchorMidX = button.midX
            under = button.minY
        } else {
            anchorMidX = visible.midX
            under = min(visible.maxY, screen.frame.maxY - menuBarHeight)
        }
        let width = panelWidth + 2 * sideMargin
        let x = clamp((anchorMidX - width / 2).rounded(.down), visible.minX, visible.maxX - width)
        let top = (under - panelGap).rounded(.down)
        return Placement(
            kind: .panel, screenID: screen.id,
            windowFrame: CGRect(x: x, y: bottom, width: width, height: top - bottom),
            anchorMidX: anchorMidX, notch: nil, bodyWidth: panelWidth
        )
    }

    /// The open island again after the displays changed (§ 3.1: re-resolved on screen
    /// changes, wake, display sleep and wake, lid open): on the same display, recomputed;
    /// nil when that display is gone, which closes the island.
    static func replacement(
        for placement: Placement, entry: IslandEntry, screens: [IslandScreen],
        statusItemFrame: CGRect?, panelWidth: CGFloat, menuBarHeight: CGFloat
    ) -> Placement? {
        screens.first { $0.id == placement.screenID }.map {
            Self.placement(
                on: $0, entry: entry, statusItemFrame: statusItemFrame,
                panelWidth: panelWidth, menuBarHeight: menuBarHeight
            )
        }
    }

    /// The resting notch panel's frame (D13): the notch rounded out to whole points, since
    /// window origins snap and the notch's edges sit on half points (P0: 663.5).
    static func restingFrame(notch: CGRect) -> CGRect {
        let minX = notch.minX.rounded(.down)
        let maxX = notch.maxX.rounded(.up)
        let minY = notch.minY.rounded(.down)
        let maxY = notch.maxY.rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether `point` is on `screen`, its top edge included: the pointer can rest there.
    private static func holds(_ screen: IslandScreen, _ point: CGPoint) -> Bool {
        let frame = screen.frame
        return point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    /// The status item the panel hangs under: the shown item as it is now (it moves with the
    /// displays), else the one a status-item entry was clicked on; nil for any other entry
    /// while the item is hidden.
    private static func itemFrame(_ entry: IslandEntry, shown: CGRect?) -> CGRect? {
        if let shown { return shown }
        if case .statusItem(let button) = entry { return button }
        return nil
    }

    /// The main display (`CGMainDisplayID`, ruling R10), else the first one.
    private static func mainScreen(_ screens: [IslandScreen], _ id: UInt32?) -> IslandScreen? {
        screens.first { $0.id == id } ?? screens.first
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}
