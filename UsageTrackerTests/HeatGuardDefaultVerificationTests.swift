import XCTest
@testable import Omelette

/// Keep-awake thermal guard spec 2026-11-19, § Settings and decision 3 (amended 2026-11-22): the
/// "End when the Mac overheats with the lid closed" switch is off by default, a user turns it on,
/// "Reset all settings" puts it back off and an armed helper hears it, and nothing else moves
/// (every `arm` still turns the helper's guard on and the app sets it to the switch from the arm's
/// reply). The model is `KeepAwakeModel.live` over the app's own store, the helper is the real
/// service over the real coding against the fake machine, and the store is put to its defaults
/// through the product's own reset. The app's preferences domain is snapshotted and handed back
/// through `AppDomainRestore`.
final class HeatGuardDefaultVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let closedLid = KeepAwakeLid(closed: true, causesSleep: true)
    private var savedDomain: [String: Any]?
    private var directory: URL!
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUpWithError() throws {
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeatGuardDefaultVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// What the wire carried, and the clock the helper answers by.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [KeepAwakeRequest] = []
        private var _now: Date
        init(now: Date) { _now = now }
        var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
        var requests: [KeepAwakeRequest] { lock.withLock { _requests } }
        func record(_ request: KeepAwakeRequest) { lock.withLock { _requests.append(request) } }
        var sets: [Bool] {
            requests.compactMap { if case .setThermalGuard(let enabled) = $0 { return enabled } else { return nil } }
        }
    }

    private struct Rig {
        var model: KeepAwakeModel
        var service: KeepAwakeService
        var fake: FakeKeepAwakeMachine
        var wire: Wire
    }

    /// The live model over `SettingsStore.shared`, the real service behind it, a Mac with the lid
    /// closed at `thermal`.
    @MainActor private func makeRig(thermal: KeepAwakeThermalLevel) async -> Rig {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.lid = closedLid; $0.thermal = thermal }
        let service = KeepAwakeService(
            machine: fake.machine(),
            stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
        )
        _ = await service.start(now: t0)
        let wire = Wire(now: t0)
        var dependencies = KeepAwakeFakeHelper(statuses: [.enabled]).dependencies()
        dependencies.send = { request in
            wire.record(request)
            let now = wire.now
            let reply: KeepAwakeReply
            switch request {
            case .arm(let seconds, let floor): reply = await service.arm(seconds: seconds, floorEnabled: floor, now: now)
            case .disarm: reply = await service.disarm(now: now)
            case .setFloor(let enabled): reply = await service.setFloor(enabled: enabled, now: now)
            case .setThermalGuard(let enabled): reply = await service.setThermalGuard(enabled: enabled, now: now)
            case .state: reply = await service.state(now: now)
            }
            guard let decoded = KeepAwakeCoding.decode(KeepAwakeReply.self, from: KeepAwakeCoding.encode(reply)) else {
                return .failure(.unreadableReply)
            }
            return .success(decoded)
        }
        let model = KeepAwakeModel.live(client: KeepAwakeClient(dependencies: dependencies), settings: .shared)
        fake.with { $0.calls = [] }
        return Rig(model: model, service: service, fake: fake, wire: wire)
    }

    /// One minute passes: the helper's tick, then the app's poll.
    @MainActor private func minute(_ rig: Rig, _ n: Int) async {
        rig.wire.now = t0 + Double(n) * 60
        _ = await rig.service.tick(now: rig.wire.now)
        await rig.model.pollIfNeeded(now: rig.wire.now)
    }

    @MainActor private func storeAtItsDefaults() -> SettingsStore {
        let settings = SettingsStore.shared
        settings.resetToDefaults()
        return settings
    }

    /// A first Apply on a store at its defaults: the arm turns the helper's guard on, the app
    /// sets it off from the arm's reply, and a hot Mac with the lid closed then ends nothing.
    @MainActor func testAFirstApplyUnderTheDefaultsLeavesTheHelpersGuardOffAndHeatEndsNothing() async {
        let settings = storeAtItsDefaults()
        XCTAssertFalse(settings.keepAwakeThermalGuardEnabled)
        let rig = await makeRig(thermal: .critical)
        await rig.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(rig.wire.sets, [false], "the arm turned the guard on; the switch's off went out after it")
        XCTAssertEqual(rig.model.helperThermalGuard, false)
        for n in 1...5 { await minute(rig, n) }
        XCTAssertEqual(rig.model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertEqual(rig.wire.sets, [false], "polls that agree send nothing")
        XCTAssertEqual(rig.fake.with { $0.calls.filter { $0 == "sleepnow" } }, [])
        XCTAssertEqual(rig.fake.with { $0.flag }, .set)
    }

    /// The user turns the switch on while armed: the helper hears it at once and heat with the
    /// lid closed then ends the mode, on a reading taken after the switch.
    @MainActor func testTurningTheSwitchOnWhileArmedReachesTheHelperAtOnceAndHeatThenEndsTheMode() async {
        let settings = storeAtItsDefaults()
        let rig = await makeRig(thermal: .critical)
        await rig.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        await minute(rig, 1)
        XCTAssertTrue(rig.model.state.isArmed)
        settings.keepAwakeThermalGuardEnabled = true
        rig.wire.now = t0 + 90
        await rig.model.thermalGuardChanged(now: rig.wire.now)
        XCTAssertEqual(rig.wire.sets, [false, true])
        XCTAssertEqual(rig.model.helperThermalGuard, true)
        XCTAssertTrue(rig.model.state.isArmed, "turning it on reads no level")
        await minute(rig, 2)
        XCTAssertEqual(rig.model.state, .ended(at: t0 + 120, reason: .overheated))
        XCTAssertEqual(rig.fake.with { $0.calls.last }, "sleepnow")
    }

    /// Reset all settings from switch-on while armed (the floor off too, so the reset is
    /// observable on both): the store goes back to the defaults, the helper hears both, and heat
    /// then ends nothing.
    @MainActor func testResetAllSettingsFromSwitchOnWhileArmedLeavesTheHelpersGuardOffAndHeatEndsNothing() async {
        let settings = storeAtItsDefaults()
        settings.keepAwakeThermalGuardEnabled = true
        settings.keepAwakeFloorEnabled = false
        let rig = await makeRig(thermal: .critical)
        await rig.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(rig.wire.sets, [], "switch on, helper's guard on: they agree")
        XCTAssertEqual(rig.model.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
        settings.resetToDefaults()
        XCTAssertFalse(settings.keepAwakeThermalGuardEnabled)
        rig.wire.now = t0 + 30
        await rig.model.allSettingsWereReset(now: rig.wire.now)
        XCTAssertEqual(rig.wire.sets.last, false)
        XCTAssertEqual(rig.model.helperThermalGuard, false)
        XCTAssertEqual(rig.model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        for n in 1...5 { await minute(rig, n) }
        XCTAssertTrue(rig.model.state.isArmed, "guard off, critical, lid closed: nothing ends")
        XCTAssertEqual(rig.fake.with { $0.calls.filter { $0 == "sleepnow" } }, [])
    }

    /// An update from 4.3.0 with a mode armed: the old helper's replies carry no `thermalGuard`.
    /// With the switch at its default nothing is sent to it and the "starts with the next Apply"
    /// line is not owed; with the switch on the line is.
    @MainActor func testAHelperThatPredatesTheGuardIsSentNothingAndTheLineFollowsTheSwitch() async {
        let settings = storeAtItsDefaults()
        let deadline = t0 + 7_200
        let old = KeepAwakeFakeHelper(statuses: [.enabled]) { _ in
            .success(KeepAwakeReply(state: .armed(deadline: deadline, floorEnabled: true), failure: nil))
        }
        let model = KeepAwakeModel.live(client: KeepAwakeClient(dependencies: old.dependencies()), settings: settings)
        await model.refresh(now: t0)
        XCTAssertTrue(model.state.isArmed)
        XCTAssertNil(model.helperThermalGuard)
        let armed = KeepAwakeCopy.Status.armed(deadline: t0 + 7_200)
        XCTAssertNil(KeepAwakeCopy.guardPendingLine(armed, helperGuard: model.helperThermalGuard, settingOn: settings.keepAwakeThermalGuardEnabled))
        settings.keepAwakeThermalGuardEnabled = true
        await model.thermalGuardChanged(now: t0 + 10)
        await model.pollIfNeeded(now: t0 + 20)
        XCTAssertEqual(old.requests, [.state, .state], "no setThermalGuard to a helper that never said it has one")
        XCTAssertEqual(
            KeepAwakeCopy.guardPendingLine(armed, helperGuard: model.helperThermalGuard, settingOn: settings.keepAwakeThermalGuardEnabled),
            KeepAwakeCopy.guardPendingText
        )
    }
}
