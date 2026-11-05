import Combine
import CoreGraphics
import XCTest
@testable import Omelette

/// Verifier's file for spec 2026-11-03 § P4 (island on displays without a notch can be turned off):
/// what `VirtualNotchSwitchTests` leaves unpinned — the height budget, the layout and the presentation
/// on a disallowed reading, every display shape of the fixtures through one invariant, an open island
/// re-placed across a flip, an ear update never making or dropping a pill across a flip, and the live
/// reading and the store's signal through the real `SettingsStore`.
final class VirtualNotchSwitchVerificationTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    private func reading(_ screens: [IslandScreen], windows: [MenuBarWindow], allowed: Bool) -> [IslandScreen] {
        IslandScreen.attached(screens, menuBarWindows: windows, virtualNotchAllowed: allowed)
    }

    private func lidOpen(allowed: Bool) -> [IslandScreen] {
        reading(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            windows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal], allowed: allowed
        )
    }

    /// A wide notchless display with a menu bar window of 24 pt (the fixtures' own `visibleFrame`
    /// heights carry the bar for the hand-built ones, but a live reading measures a window).
    private func notchless(_ screen: IslandScreen, bar: CGFloat, mainHeight: CGFloat) -> MenuBarWindow {
        MenuBarWindow(
            ownerName: "Window Server", layer: 24,
            boundsCG: CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: bar)
        )
    }

    // MARK: - One invariant over every display shape

    /// Off, a display carries an island exactly when it has a camera housing, and then it is the
    /// housing; on, the virtual notch is still `VirtualNotchRules`' answer, unchanged by the switch.
    func testOffEveryDisplayShapeIslandIsTheCameraHousingOrNothing() {
        let shapes: [IslandScreen] = [
            ScreenFixture.builtIn, ScreenFixture.narrowNotched, ScreenFixture.externalRight,
            ScreenFixture.externalLeft, ScreenFixture.wide1280, ScreenFixture.narrow1279,
            ScreenFixture.externalRightMenuBarHidden, ScreenFixture.externalLeftMenuBarHidden,
            ScreenFixture.secondaryExternal, ScreenFixture.lidClosedExternal
        ]
        for shape in shapes {
            var off = shape
            off.virtualNotchAllowed = false
            var on = shape
            on.virtualNotchAllowed = true
            XCTAssertEqual(off.islandNotch, off.notchRect, "off, id \(shape.id) \(shape.frame)")
            XCTAssertEqual(off.hasNotch, on.hasNotch, "the physical notch is not the switch's")
            XCTAssertEqual(off.notchRect, on.notchRect)
            if on.hasNotch {
                XCTAssertEqual(on.islandNotch, off.islandNotch, "a camera housing is unaffected")
            } else {
                XCTAssertEqual(
                    on.islandNotch, VirtualNotchRules.rect(screen: on, referenceNotchWidth: on.referenceNotchWidth),
                    "on is 4.1's rule, id \(shape.id)"
                )
            }
        }
    }

    /// The hidden-bar and narrow combos have no virtual notch with the switch on either, so the switch
    /// changes nothing there: pills, ears and the status item agree between the two readings.
    func testWhereNoVirtualNotchWasPossibleTheSwitchChangesNothing() {
        let narrow = ScreenFixture.narrow1279
        let hidden = ScreenFixture.externalRightMenuBarHidden
        for screens in [[narrow], [hidden], [narrow, hidden]] {
            let on = reading(screens, windows: [], allowed: true)
            let off = reading(screens, windows: [], allowed: false)
            XCTAssertEqual(RestingPillRules.pills(on), RestingPillRules.pills(off))
            XCTAssertEqual(
                StatusItemVisibilityRules.islandDisplayAttached(on), StatusItemVisibilityRules.islandDisplayAttached(off)
            )
            XCTAssertEqual(on.map(\.islandNotch), off.map(\.islandNotch))
        }
    }

    /// The narrow notchless display next to a MacBook, off: the MacBook keeps its pill, nothing else
    /// moves; on: 1279 pt still gets none.
    func testANotchlessDisplayUnderTheFloorNextToAMacBookNeverHadAPill() {
        let windows = [MenuBarWindowFixture.builtIn, notchless(ScreenFixture.narrow1279, bar: 24, mainHeight: 982)]
        let screens = [ScreenFixture.builtIn, ScreenFixture.narrow1279]
        XCTAssertEqual(RestingPillRules.pills(reading(screens, windows: windows, allowed: true)).map(\.displayID), [1])
        XCTAssertEqual(RestingPillRules.pills(reading(screens, windows: windows, allowed: false)).map(\.displayID), [1])
    }

    /// Two notchless displays and the lid closed: off, no pill, no island display anywhere, the icon
    /// forced on whatever Show in menu bar says.
    func testTwoNotchlessDisplaysOffLeaveNoIslandAndForceTheIcon() {
        let screens = [ScreenFixture.lidClosedExternal, ScreenFixture.externalLeft]
        let windows = [MenuBarWindowFixture.lidClosedExternal, notchless(ScreenFixture.externalLeft, bar: 24, mainHeight: 1440)]
        XCTAssertEqual(RestingPillRules.pills(reading(screens, windows: windows, allowed: true)).count, 2)
        let off = reading(screens, windows: windows, allowed: false)
        XCTAssertEqual(RestingPillRules.pills(off), [])
        XCTAssertNil(IslandDisplayResolver.primaryIslandScreen(off))
        let attached = StatusItemVisibilityRules.islandDisplayAttached(off)
        XCTAssertFalse(attached)
        XCTAssertTrue(StatusItemVisibilityRules.isShown(setting: false, islandDisplayAttached: attached))
    }

    // MARK: - Height, layout and presentation follow

    func testOffTheHeightBudgetOnANotchlessDisplayIsThePanelsAndTheIslandsOnTheNotchedOneIsKept() {
        var screen = reading(
            [ScreenFixture.lidClosedExternal], windows: [MenuBarWindowFixture.lidClosedExternal], allowed: true
        )[0]
        let visible = screen.visibleFrame.height
        let islandBudget = IslandHeightRules.budget(on: screen, screenVisibleHeight: visible)
        let islandRight = IslandHeightRules.rightColumnBudget(on: screen, screenVisibleHeight: visible)
        XCTAssertNotEqual(islandBudget, PopoverHeightRules.budget(screenVisibleHeight: visible))

        screen.virtualNotchAllowed = false
        XCTAssertEqual(
            IslandHeightRules.budget(on: screen, screenVisibleHeight: visible),
            PopoverHeightRules.budget(screenVisibleHeight: visible)
        )
        XCTAssertEqual(
            IslandHeightRules.rightColumnBudget(on: screen, screenVisibleHeight: visible),
            PopoverHeightRules.budget(screenVisibleHeight: visible)
                - IslandHeightRules.outsideRightColumn(.panel)
        )
        XCTAssertNotEqual(IslandHeightRules.rightColumnBudget(on: screen, screenVisibleHeight: visible), islandRight)

        var notched = ScreenFixture.builtIn
        let before = IslandHeightRules.budget(on: notched, screenVisibleHeight: 872)
        notched.virtualNotchAllowed = false
        XCTAssertEqual(IslandHeightRules.budget(on: notched, screenVisibleHeight: 872), before)
        XCTAssertEqual(
            IslandHeightRules.rightColumnBudget(on: notched, screenVisibleHeight: 872),
            before - IslandHeightRules.outsideRightColumn(.island)
        )
    }

    func testOffTheLayoutOnANotchlessDisplayIsThePanelAndTheNotchedOnesIsTheIsland() {
        var screen = reading(
            [ScreenFixture.lidClosedExternal], windows: [MenuBarWindowFixture.lidClosedExternal], allowed: true
        )[0]
        let on = IslandLayout(on: screen, petOn: true)
        XCTAssertEqual(on.kind, .island)
        XCTAssertEqual(on.stripHeight, 30)

        screen.virtualNotchAllowed = false
        let off = IslandLayout(on: screen, petOn: true)
        XCTAssertEqual(off.kind, .panel)
        XCTAssertEqual(off.stripHeight, 0)
        XCTAssertEqual(off.notchWidth, 0)
        XCTAssertEqual(off.bodyWidth, IslandPresentationRules.width(screenWidth: screen.frame.width))

        var notched = ScreenFixture.builtIn
        let housing = IslandLayout(on: notched, petOn: true)
        notched.virtualNotchAllowed = false
        XCTAssertEqual(IslandLayout(on: notched, petOn: true), housing)
        XCTAssertEqual(housing.kind, .island)
    }

    @MainActor
    func testTheLayoutModelPlacedOnANotchlessDisplayFollowsTheSwitch() {
        let model = IslandLayoutModel(petOn: { true })
        var screen = reading(
            [ScreenFixture.lidClosedExternal], windows: [MenuBarWindowFixture.lidClosedExternal], allowed: false
        )[0]
        model.place(on: screen, visibleHeight: screen.visibleFrame.height)
        XCTAssertEqual(model.layout.kind, .panel)
        screen.virtualNotchAllowed = true
        model.place(on: screen, visibleHeight: screen.visibleFrame.height)
        XCTAssertEqual(model.layout.kind, .island)
    }

    // MARK: - An open island across a flip

    /// The island open on the notchless display as a notch entry, then the switch goes off: the
    /// replacement is the panel on the same display (not nil, which would close it), and on again
    /// brings the island back centred on the virtual notch.
    func testAnIslandOpenOnTheNotchlessDisplayBecomesThePanelAcrossTheFlipAndBack() throws {
        let entry = IslandEntry.notch(displayID: 2)
        let on = lidOpen(allowed: true)
        let open = try XCTUnwrap(IslandDisplayResolver.placement(
            for: entry, screens: on, mainScreenID: 1, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        ))
        XCTAssertEqual(open.kind, .island)

        let off = lidOpen(allowed: false)
        let panel = try XCTUnwrap(IslandDisplayResolver.replacement(
            for: open, entry: entry, screens: off, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        ))
        XCTAssertEqual(panel.kind, .panel)
        XCTAssertEqual(panel.screenID, 2)
        XCTAssertNil(panel.notch)
        let external = try XCTUnwrap(off.first { $0.id == 2 })
        XCTAssertTrue(external.visibleFrame.contains(panel.windowFrame.insetBy(dx: 1, dy: 1)), "inside its display")

        let back = try XCTUnwrap(IslandDisplayResolver.replacement(
            for: panel, entry: entry, screens: on, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        ))
        XCTAssertEqual(back, open)
    }

    /// The island open on the MacBook's housing is the same placement with the switch either way.
    func testAnIslandOpenOnTheCameraHousingDoesNotMoveWithTheSwitch() throws {
        let entry = IslandEntry.notch(displayID: 1)
        func placed(_ allowed: Bool) throws -> IslandDisplayResolver.Placement {
            try XCTUnwrap(IslandDisplayResolver.placement(
                for: entry, screens: lidOpen(allowed: allowed), mainScreenID: 1,
                statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
            ))
        }
        let allowed = try placed(true)
        let disallowed = try placed(false)
        XCTAssertEqual(allowed, disallowed)
    }

    /// A notification route with the pointer on the notchless display, off: the panel there, as 4.0.
    func testANotificationOnTheNotchlessDisplayOffOpensThePanelThere() throws {
        let off = lidOpen(allowed: false)
        let pointer = CGPoint(x: 3000, y: 500)
        let placement = try XCTUnwrap(IslandDisplayResolver.placement(
            for: .notification(pointer: pointer), screens: off, mainScreenID: 1,
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        ))
        XCTAssertEqual(placement.screenID, 2)
        XCTAssertEqual(placement.kind, .panel)
    }

    // MARK: - Ears

    private func mood() -> PetMoodInput {
        PetMoodInput(
            sessions: [Fixture.agentSession(sessionID: "a", projectName: "Usage tracker", state: .needsYou)],
            services: [], enabledIDs: ["claude"], claudeBinaryFound: true, keepAwake: .idle
        )
    }

    private func ears(on screens: [IslandScreen]) -> IslandEars {
        IslandEarRules.ears(
            mood: mood(), mode: .used, petOn: true, earsOn: true, showInMenuBar: nil, screens: screens,
            now: PetRuntimeFixture.t0, calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_GB")
        )
    }

    /// The one-display view reads the primary island display: off, the MacBook's; clamshell off, none.
    func testThePrimaryDisplaysEarsFollowTheSwitchOnANotchlessOnlySetup() {
        let closedOn = reading(
            [ScreenFixture.lidClosedExternal], windows: [MenuBarWindowFixture.lidClosedExternal], allowed: true
        )
        let closedOff = reading(
            [ScreenFixture.lidClosedExternal], windows: [MenuBarWindowFixture.lidClosedExternal], allowed: false
        )
        XCTAssertNotEqual(ears(on: closedOn), .none)
        XCTAssertEqual(ears(on: closedOff), .none)
        XCTAssertNotEqual(ears(on: lidOpen(allowed: false)), .none)
    }

    // MARK: - An ear update never makes or drops a pill

    /// 4.1.0 release review: only a re-place point changes the pill set. `relaid` lays the kept
    /// pills on the reading they were placed from; a reading that carries a flip afterwards neither
    /// creates the pill the new reading wants nor lays one the new reading no longer wants.
    func testAnEarUpdateAcrossAFlipLaysOnlyTheKeptPills() {
        let keptWhenOn: Set<UInt32> = [1, 2]
        XCTAssertEqual(RestingPillRules.relaid(kept: keptWhenOn, screens: lidOpen(allowed: false)).map(\.displayID), [1])
        XCTAssertEqual(RestingPillRules.relaid(kept: keptWhenOn, screens: lidOpen(allowed: true)).map(\.displayID), [1, 2])

        let keptWhenOff: Set<UInt32> = [1]
        XCTAssertEqual(RestingPillRules.relaid(kept: keptWhenOff, screens: lidOpen(allowed: true)).map(\.displayID), [1])
        XCTAssertEqual(RestingPillRules.relaid(kept: [], screens: lidOpen(allowed: true)), [])
        XCTAssertEqual(
            RestingPillRules.relaid(kept: keptWhenOff, screens: lidOpen(allowed: false)).first?.notch,
            ScreenFixture.builtIn.notchRect
        )
    }

    /// A flip that does not change which displays carry an island (MacBook only, or a display that
    /// never had one) changes no pill: `changes` is empty either way.
    func testAFlipOnADisplaySetWithNoNotchlessIslandChangesNoPill() {
        let macOnly = reading([ScreenFixture.builtIn], windows: [MenuBarWindowFixture.builtIn], allowed: true)
        let macOnlyOff = reading([ScreenFixture.builtIn], windows: [MenuBarWindowFixture.builtIn], allowed: false)
        XCTAssertTrue(RestingPillRules.changes(kept: [1], wanted: RestingPillRules.pills(macOnly)).isEmpty)
        XCTAssertTrue(RestingPillRules.changes(kept: [1], wanted: RestingPillRules.pills(macOnlyOff)).isEmpty)
        XCTAssertEqual(RestingPillRules.pills(macOnly), RestingPillRules.pills(macOnlyOff))
    }

    // MARK: - The live reading and the store

    /// "Every reading of `IslandScreen.current()` carries the setting": whatever displays this Mac has,
    /// each one says what the store says.
    @MainActor
    func testTheLiveReadingCarriesTheStoresValueOnEveryDisplay() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        XCTAssertTrue(IslandScreen.current().allSatisfy(\.virtualNotchAllowed))
        settings.virtualNotchEnabled = false
        let off = IslandScreen.current()
        XCTAssertFalse(off.isEmpty)
        XCTAssertTrue(off.allSatisfy { !$0.virtualNotchAllowed })
        XCTAssertTrue(off.allSatisfy { $0.islandNotch == $0.notchRect })
        settings.virtualNotchEnabled = true
        XCTAssertTrue(IslandScreen.current().allSatisfy(\.virtualNotchAllowed))
    }

    /// The real store through the real signal: a flip lands once with the new value in the store, a
    /// same-value write and the subscription itself send nothing, Reset from off is heard as a flip.
    @MainActor
    func testTheStoresSignalHearsAFlipOnceAndResetAsAFlip() {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        var read: [Bool] = []
        let heard = expectation(description: "flip heard")
        let watch = IslandController.virtualNotchSwitchSignal(settings.$virtualNotchEnabled)
            .sink {
                read.append(settings.virtualNotchEnabled)
                heard.fulfill()
            }
        settings.virtualNotchEnabled = true
        settings.virtualNotchEnabled = false
        settings.virtualNotchEnabled = false
        wait(for: [heard], timeout: 5)
        watch.cancel()
        XCTAssertEqual(read, [false])
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsStore.virtualNotchEnabledKey) as? Bool, false)

        let resetHeard = expectation(description: "reset heard")
        let more = IslandController.virtualNotchSwitchSignal(settings.$virtualNotchEnabled)
            .sink { resetHeard.fulfill() }
        settings.resetToDefaults()
        wait(for: [resetHeard], timeout: 5)
        more.cancel()
        XCTAssertTrue(settings.virtualNotchEnabled)
    }

    /// Off then on inside one turn of the main queue: the signal may send twice, never none, and
    /// every send finds the final value in the store.
    @MainActor
    func testAFlipAndBackInOneTurnNeverLeavesTheReadingBehindTheStore() {
        final class Switch: ObservableObject { @Published var on = true }
        let store = Switch()
        var read: [Bool] = []
        let done = expectation(description: "drained")
        let watch = IslandController.virtualNotchSwitchSignal(store.$on).sink {
            read.append(store.on)
        }
        store.on = false
        store.on = true
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 5)
        watch.cancel()
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read, [true, true], "each reading reads the landed value, so the pills end on it")
    }
}
