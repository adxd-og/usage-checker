import XCTest
@testable import Omelette

/// Settings › Advanced › Reset all settings puts the battery floor and the heat guard back to
/// their defaults (the floor on, the guard off since 2026-11-22), and an armed helper hears both
/// at once, the floor first, as it would from the switches themselves: keep-awake spec
/// 2026-10-26, § Behaviour › Floor switch while armed; thermal guard spec 2026-11-19, § Settings
/// ("A change while armed reaches the daemon at once").
final class KeepAwakeAllSettingsResetTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    /// The two switches as the model reads them from the store.
    @MainActor private final class Prefs {
        var floor = false
        var guardOn = false
    }

    @MainActor private func makeModel(_ helper: KeepAwakeFakeHelper, _ prefs: Prefs) -> KeepAwakeModel {
        KeepAwakeModel(
            client: KeepAwakeClient(dependencies: helper.dependencies()),
            floorEnabled: { prefs.floor },
            rememberDuration: { _ in },
            resetSettings: {},
            thermalGuardEnabled: { prefs.guardOn }
        )
    }

    /// A model that heard an armed helper holding both switches away from their defaults (the
    /// floor off, the guard on), as Settings had them, and then the store as Reset all settings
    /// leaves it.
    @MainActor private func armedAwayFromTheDefaults(_ helper: KeepAwakeFakeHelper) async -> KeepAwakeModel {
        let prefs = Prefs()
        prefs.guardOn = true
        let model = makeModel(helper, prefs)
        await model.refresh(now: t0)
        XCTAssertEqual(helper.requests, [.state])
        prefs.floor = SettingsStore.Defaults.keepAwakeFloorEnabled
        prefs.guardOn = SettingsStore.Defaults.keepAwakeThermalGuardEnabled
        return model
    }

    /// The floor goes first. Its answer still says the guard is on, so the reconciliation sends
    /// the guard from it, and the guard's own call sends it again: the calls the two switches
    /// would make, one after the other.
    @MainActor func testAnArmedHelperHoldingTheFloorOffAndTheGuardOnHearsTheFloorFirstAndHoldsTheFloorOnAndTheGuardOff() async {
        let switches = KeepAwakeHeldSwitches(floor: false, guardOn: true)
        let helper = switches.helper(armedUntil: t0 + 7_200)
        let model = await armedAwayFromTheDefaults(helper)
        await model.allSettingsWereReset(now: t0 + 60)
        XCTAssertEqual(helper.requests, [
            .state,
            .setFloor(enabled: true),
            .setThermalGuard(enabled: false),
            .setThermalGuard(enabled: false),
        ])
        XCTAssertTrue(switches.floor)
        XCTAssertFalse(switches.guardOn)
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertEqual(model.helperThermalGuard, false)
        XCTAssertFalse(model.isWorking)
    }

    /// The helper took the floor but its answer was lost, so nothing reconciles the guard: the
    /// guard's own call is the one that turns it back off, sent once, after the floor.
    @MainActor func testTheGuardIsSentOnceAfterTheFloorWhenTheFloorsAnswerIsLost() async {
        let switches = KeepAwakeHeldSwitches(floor: false, guardOn: true)
        let helper = switches.helper(armedUntil: t0 + 7_200)
        let answer = helper.with { $0.reply }
        helper.with { s in
            s.reply = { request in
                let result = answer(request)
                if case .setFloor = request { return .failure(.helperTimedOut) }
                return result
            }
        }
        let model = await armedAwayFromTheDefaults(helper)
        await model.allSettingsWereReset(now: t0 + 60)
        XCTAssertEqual(helper.requests, [.state, .setFloor(enabled: true), .setThermalGuard(enabled: false)])
        XCTAssertTrue(switches.floor)
        XCTAssertFalse(switches.guardOn)
        XCTAssertEqual(model.helperThermalGuard, false)
    }

    @MainActor func testWithNothingArmedTheHelperHearsNothing() async {
        let helper = KeepAwakeHeldSwitches(floor: false, guardOn: false).helper(armedUntil: t0 + 7_200)
        let prefs = Prefs()
        prefs.floor = true
        prefs.guardOn = true
        let model = makeModel(helper, prefs)
        await model.allSettingsWereReset(now: t0)
        XCTAssertEqual(helper.requests, [])
    }
}
