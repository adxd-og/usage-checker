import XCTest
@testable import Omelette

/// The battery floor and the heat guard as a ready helper holds them, armed until a fixed
/// deadline. As the engine does, an `arm` takes the floor it carries and turns the guard on,
/// `setFloor` and `setThermalGuard` set theirs, and every answer says what it holds. Internal:
/// `KeepAwakeAllSettingsResetTests` drives it too.
final class KeepAwakeHeldSwitches: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (floor: Bool, guardOn: Bool)

    init(floor: Bool, guardOn: Bool) {
        held = (floor, guardOn)
    }

    var floor: Bool { lock.withLock { held.floor } }
    var guardOn: Bool { lock.withLock { held.guardOn } }

    func helper(armedUntil deadline: Date) -> KeepAwakeFakeHelper {
        KeepAwakeFakeHelper(statuses: [.enabled]) { request in
            self.lock.withLock {
                switch request {
                case .arm(_, let floorEnabled):
                    self.held = (floorEnabled, true)
                case .setFloor(let enabled):
                    self.held.floor = enabled
                case .setThermalGuard(let enabled):
                    self.held.guardOn = enabled
                case .disarm, .state:
                    break
                }
                return .success(KeepAwakeReply(
                    state: .armed(deadline: deadline, floorEnabled: self.held.floor),
                    failure: nil,
                    thermal: .nominal,
                    thermalGuard: self.held.guardOn
                ))
            }
        }
    }
}

/// The model as `KeepAwakeModel.shared` is built (`KeepAwakeModel.live`), over the app's
/// settings store and a stand-in `ProcessInfo`. Thermal guard spec 2026-11-19, § Settings ("A
/// change while armed reaches the daemon at once") and § What the user sees ("The app reads
/// the level itself for this line"); keep-awake spec 2026-10-26, § Behaviour › Floor switch
/// while armed and § UI (last used values remembered; Reset keep awake). The app's
/// preferences domain is snapshotted and handed back through `AppDomainRestore`.
final class KeepAwakeLiveModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var savedDomain: [String: Any]?
    private var domainName: String {
        Bundle.main.bundleIdentifier ?? "com.usagetracker.app"
    }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    @MainActor private func makeModel(
        _ helper: KeepAwakeFakeHelper,
        _ processInfo: ProcessInfo = KeepAwakeStubProcessInfo(.nominal)
    ) -> KeepAwakeModel {
        KeepAwakeModel.live(
            client: KeepAwakeClient(dependencies: helper.dependencies()),
            settings: SettingsStore.shared,
            processInfo: processInfo
        )
    }

    /// The store says off while the helper holds the guard on: the reply's reconciliation sends
    /// off. The store turned back on: the next reply's sends on.
    @MainActor func testTheHeatSwitchIsReadFromTheSettingsStore() async {
        let settings = SettingsStore.shared
        let switches = KeepAwakeHeldSwitches(floor: true, guardOn: true)
        let helper = switches.helper(armedUntil: t0 + 7_200)
        let model = makeModel(helper)
        settings.keepAwakeThermalGuardEnabled = false
        await model.refresh(now: t0)
        XCTAssertEqual(helper.requests, [.state, .setThermalGuard(enabled: false)])
        XCTAssertFalse(switches.guardOn)
        settings.keepAwakeThermalGuardEnabled = true
        await model.pollIfNeeded(now: t0 + 60)
        XCTAssertEqual(helper.requests, [.state, .setThermalGuard(enabled: false), .state, .setThermalGuard(enabled: true)])
        XCTAssertTrue(switches.guardOn)
    }

    @MainActor func testApplyTakesTheFloorFromTheSettingsStore() async {
        let settings = SettingsStore.shared
        let helper = KeepAwakeHeldSwitches(floor: true, guardOn: true).helper(armedUntil: t0 + 7_200)
        let model = makeModel(helper)
        settings.keepAwakeThermalGuardEnabled = true
        settings.keepAwakeFloorEnabled = false
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        settings.keepAwakeFloorEnabled = true
        await model.arm(days: 0, hours: 2, minutes: 0, now: t0 + 60)
        XCTAssertEqual(helper.requests, [
            .arm(seconds: 7_200, floorEnabled: false),
            .arm(seconds: 7_200, floorEnabled: true),
        ])
    }

    @MainActor func testApplyRemembersTheDurationInTheSettingsStore() async {
        let settings = SettingsStore.shared
        let model = makeModel(KeepAwakeHeldSwitches(floor: true, guardOn: true).helper(armedUntil: t0 + 5_400))
        settings.keepAwakeDurationMinutes = 60
        await model.arm(days: 0, hours: 1, minutes: 30, now: t0)
        XCTAssertEqual(settings.keepAwakeDurationMinutes, 90)
    }

    @MainActor func testResetKeepAwakePutsTheStoresThreeSettingsBack() async {
        let settings = SettingsStore.shared
        let model = makeModel(KeepAwakeHeldSwitches(floor: true, guardOn: true).helper(armedUntil: t0 + 7_200))
        settings.keepAwakeFloorEnabled = false
        settings.keepAwakeThermalGuardEnabled = false
        settings.keepAwakeDurationMinutes = 5
        await model.reset(now: t0)
        XCTAssertTrue(settings.keepAwakeFloorEnabled)
        XCTAssertTrue(settings.keepAwakeThermalGuardEnabled)
        XCTAssertEqual(settings.keepAwakeDurationMinutes, 60)
    }

    /// The card's "running hot" line reads the live level each time it reads.
    @MainActor func testTheCardsLevelIsTheLiveReading() {
        let processInfo = KeepAwakeStubProcessInfo(.serious)
        let model = makeModel(KeepAwakeFakeHelper(statuses: [.enabled]), processInfo)
        model.readThermal()
        XCTAssertEqual(model.thermal, .serious)
        processInfo.set(.critical)
        model.readThermal()
        XCTAssertEqual(model.thermal, .critical)
        processInfo.set(.fair)
        model.readThermal()
        XCTAssertEqual(model.thermal, .fair)
    }
}
