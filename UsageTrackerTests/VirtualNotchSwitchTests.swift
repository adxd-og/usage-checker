import Combine
import CoreGraphics
import XCTest
@testable import Omelette

/// Spec 2026-11-03 § P4 (island on displays without a notch can be turned off): with the switch
/// off, a reading carries no virtual notch, and everything downstream falls back to 4.0 on a display
/// without a camera housing — no pill, no ears, the panel, the status item forced on only while no
/// display has a physical notch. A camera housing keeps its island either way. Flipping the switch is
/// a re-place point, heard once per change and after the new value has landed.
final class VirtualNotchSwitchTests: XCTestCase {
    private let now = PetRuntimeFixture.t0
    private let locale = Locale(identifier: "en_GB")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The owner's MacBook with the lid open and the 2560 x 1440 external beside it, as measured on
    /// 2026-11-03, read with the switch as given.
    private func lidOpen(allowed: Bool) -> [IslandScreen] {
        IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal],
            virtualNotchAllowed: allowed
        )
    }

    /// The same external with the lid closed: no camera housing attached.
    private func lidClosed(allowed: Bool) -> [IslandScreen] {
        IslandScreen.attached(
            [ScreenFixture.lidClosedExternal],
            menuBarWindows: [MenuBarWindowFixture.lidClosedExternal],
            virtualNotchAllowed: allowed
        )
    }

    private func waiting(_ id: String) -> AgentSession {
        Fixture.agentSession(sessionID: id, projectName: "Usage tracker", state: .needsYou)
    }

    private func ears(on screens: [IslandScreen]) -> [UInt32: IslandEars] {
        IslandEarRules.earsByDisplay(
            mood: PetMoodInput(
                sessions: [waiting("a")], services: [], enabledIDs: ["claude"],
                claudeBinaryFound: true, keepAwake: .idle
            ),
            mode: .used, petOn: true, earsOn: true, showInMenuBar: nil,
            screens: screens, now: now, calendar: utc, locale: locale
        )
    }

    private func placement(_ entry: IslandEntry, on screens: [IslandScreen], statusItemFrame: CGRect? = nil)
        -> IslandDisplayResolver.Placement? {
        IslandDisplayResolver.placement(
            for: entry, screens: screens, mainScreenID: screens.first?.id,
            statusItemFrame: statusItemFrame, panelWidth: 360, menuBarHeight: 24
        )
    }

    // MARK: - The reading

    func testANotchlessDisplayWithAMenuBarLosesItsVirtualNotchWhenNotAllowed() {
        var screen = ScreenFixture.externalLeft
        XCTAssertEqual(screen.frame.width, 1920)
        XCTAssertNotNil(screen.islandNotch, "allowed, a 1920 pt display with a menu bar gets the pill")

        screen.virtualNotchAllowed = false

        XCTAssertNil(screen.islandNotch)
        XCTAssertNil(screen.notchRect)
        XCTAssertFalse(screen.hasNotch)
    }

    func testACameraHousingKeepsItsIslandWhateverTheSwitch() {
        var screen = ScreenFixture.builtIn
        let housing = screen.notchRect
        XCTAssertNotNil(housing)
        XCTAssertEqual(screen.islandNotch, housing)

        screen.virtualNotchAllowed = false

        XCTAssertEqual(screen.islandNotch, housing)
        XCTAssertTrue(screen.hasNotch)
    }

    func testADisplayBuiltByHandAllowsTheVirtualNotch() {
        XCTAssertTrue(ScreenFixture.externalRight.virtualNotchAllowed)
        XCTAssertTrue(IslandScreen.attached([ScreenFixture.externalRight]).allSatisfy(\.virtualNotchAllowed))
        XCTAssertTrue(
            IslandScreen.attached([ScreenFixture.builtIn], menuBarWindows: [MenuBarWindowFixture.builtIn])
                .allSatisfy(\.virtualNotchAllowed)
        )
    }

    /// One reading, one answer: every display in it carries the switch, the measurements unchanged.
    func testTheReadingCarriesTheSwitchToEveryDisplay() {
        let off = lidOpen(allowed: false)
        XCTAssertEqual(off.map(\.virtualNotchAllowed), [false, false])
        XCTAssertEqual(off.map(\.menuBarHeight), [33, 30])
        XCTAssertEqual(off.map(\.referenceNotchWidth), [185, 185])

        let on = lidOpen(allowed: true)
        XCTAssertEqual(on.map(\.virtualNotchAllowed), [true, true])
        XCTAssertEqual(on.map(\.menuBarHeight), [33, 30])
    }

    // MARK: - Downstream follows

    func testOffThePillOnTheNotchlessDisplayGoesAndTheNotchedOneStays() {
        let on = RestingPillRules.pills(lidOpen(allowed: true))
        XCTAssertEqual(on.map(\.displayID), [1, 2])

        let off = RestingPillRules.pills(lidOpen(allowed: false))
        XCTAssertEqual(off, [RestingPillRules.Pill(displayID: 1, notch: ScreenFixture.builtIn.notchRect!)])

        XCTAssertEqual(RestingPillRules.pills(lidClosed(allowed: false)), [])
        XCTAssertEqual(RestingPillRules.pills(lidClosed(allowed: true)).map(\.displayID), [2])
    }

    /// The flip is a re-place point: the pills placed on the last reading become those of the new one.
    func testTheFlipDropsAndMakesTheNotchlessDisplaysPill() {
        let off = RestingPillRules.changes(kept: [1, 2], wanted: RestingPillRules.pills(lidOpen(allowed: false)))
        XCTAssertEqual(off, RestingPillRules.Changes(create: [], drop: [2]))

        let backOn = RestingPillRules.changes(kept: [1], wanted: RestingPillRules.pills(lidOpen(allowed: true)))
        XCTAssertEqual(backOn, RestingPillRules.Changes(create: [2], drop: []))
    }

    func testOffTheNotchlessDisplayHasNoEars() {
        let on = ears(on: lidOpen(allowed: true))
        XCTAssertEqual(Set(on.keys), [1, 2])

        let off = ears(on: lidOpen(allowed: false))
        XCTAssertEqual(Set(off.keys), [1])
        XCTAssertNotNil(off[1]?.left, "the MacBook's ears still say an agent waits")

        XCTAssertEqual(ears(on: lidClosed(allowed: false)), [:])
    }

    func testOffTheResolverOpensThePanelOnTheNotchlessDisplay() {
        XCTAssertEqual(placement(.notch(displayID: 2), on: lidOpen(allowed: true))?.kind, .island)

        let off = lidOpen(allowed: false)
        XCTAssertEqual(placement(.notch(displayID: 2), on: off)?.kind, .panel)
        XCTAssertEqual(placement(.ear(displayID: 2), on: off)?.kind, .panel)
        XCTAssertEqual(placement(.notch(displayID: 1), on: off)?.kind, .island)
        XCTAssertNil(placement(.notch(displayID: 2), on: off)?.notch)
        XCTAssertEqual(IslandDisplayResolver.primaryIslandScreen(off)?.id, 1)
    }

    /// 4.0's notchless setup: the panel hangs under the status item, which is the way in.
    func testOffWithTheLidClosedThePanelHangsUnderTheStatusItem() {
        let screens = lidClosed(allowed: false)
        let button = CGRect(x: 2000, y: 1416, width: 60, height: 24)
        let panel = placement(.statusItem(buttonFrame: button), on: screens, statusItemFrame: button)
        XCTAssertEqual(panel?.kind, .panel)
        XCTAssertEqual(panel?.screenID, 2)
        XCTAssertEqual(panel?.anchorMidX, button.midX)
        XCTAssertNil(IslandDisplayResolver.primaryIslandScreen(screens))
    }

    /// A pill clicked between the flip and the re-place still opens, as the panel, and the pills catch up.
    func testAPillClickedAfterTheFlipIsStale() {
        XCTAssertTrue(IslandDisplayResolver.clickedPillIsStale(.notch(displayID: 2), screens: lidOpen(allowed: false)))
        XCTAssertFalse(IslandDisplayResolver.clickedPillIsStale(.notch(displayID: 1), screens: lidOpen(allowed: false)))
        XCTAssertFalse(IslandDisplayResolver.clickedPillIsStale(.notch(displayID: 2), screens: lidOpen(allowed: true)))
    }

    // MARK: - The status item

    func testOffAnIslandDisplayIsAttachedOnlyWithACameraHousing() {
        XCTAssertFalse(StatusItemVisibilityRules.islandDisplayAttached(lidClosed(allowed: false)))
        XCTAssertTrue(StatusItemVisibilityRules.islandDisplayAttached(lidOpen(allowed: false)))
        XCTAssertTrue(StatusItemVisibilityRules.islandDisplayAttached(lidClosed(allowed: true)))
    }

    /// Clamshell or a Mac mini with the switch off: the icon is forced on, its switch held, as in 4.0.
    func testOffWithNoCameraHousingTheIconIsForcedOn() {
        let attached = StatusItemVisibilityRules.islandDisplayAttached(lidClosed(allowed: false))
        for setting: Bool? in [nil, false, true] {
            XCTAssertTrue(
                StatusItemVisibilityRules.isShown(setting: setting, islandDisplayAttached: attached),
                "\(String(describing: setting))"
            )
        }
        XCTAssertFalse(StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: attached))
        XCTAssertEqual(
            StatusItemVisibilityRules.caption(islandDisplayAttached: attached),
            "Always on while no display shows the island."
        )
    }

    /// The MacBook open with an external and the switch off: Show in menu bar governs, off by default.
    func testOffWithAMacBookNotchShowInMenuBarGoverns() {
        let attached = StatusItemVisibilityRules.islandDisplayAttached(lidOpen(allowed: false))
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: nil, islandDisplayAttached: attached))
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: false, islandDisplayAttached: attached))
        XCTAssertTrue(StatusItemVisibilityRules.isShown(setting: true, islandDisplayAttached: attached))
        XCTAssertTrue(StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: attached))
    }

    // MARK: - The flip is heard

    /// Stands in for `SettingsStore`: a real `@Published`, which sends before the value lands.
    @MainActor
    private final class Switch: ObservableObject {
        @Published var on = true
    }

    /// Not the value at subscription (the launch has placed on it), not a write of the same value; each
    /// change once, on the main thread, with the new value already in the store when it is read.
    @MainActor
    func testEachFlipIsHeardOnceAfterTheValueLanded() {
        let store = Switch()
        var read: [Bool] = []
        let heardOff = expectation(description: "off heard")
        let heardOn = expectation(description: "on heard")
        let watch = IslandController.virtualNotchSwitchSignal(store.$on)
            .sink {
                XCTAssertTrue(Thread.isMainThread)
                read.append(store.on)
                if read.count == 1 { heardOff.fulfill() }
                if read.count == 2 { heardOn.fulfill() }
            }

        store.on = true
        store.on = false
        store.on = false
        wait(for: [heardOff], timeout: 5)
        store.on = true
        wait(for: [heardOn], timeout: 5)
        watch.cancel()

        XCTAssertEqual(read, [false, true])
    }
}
