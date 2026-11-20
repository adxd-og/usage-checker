import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § What the user sees: "Armed and warm: while the
/// level is `serious` or `critical` the card says so under the countdown ("The Mac is running
/// hot"), lid open or closed. The app reads the level itself for this line." And § Accepted
/// risks: "The card says so while an armed helper answers without `thermalGuard`: "The heat
/// guard starts with the next Apply.""
final class KeepAwakeRunningHotTests: XCTestCase {
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)
    private var armed: KeepAwakeCopy.Status { .armed(deadline: now.addingTimeInterval(3_600)) }

    /// A level the tests change between reads.
    @MainActor private final class LevelSource {
        var level: KeepAwakeThermalLevel = .nominal
    }

    @MainActor private func makeModel(_ level: @escaping @MainActor () -> KeepAwakeThermalLevel) -> KeepAwakeModel {
        KeepAwakeModel(
            client: KeepAwakeClient(dependencies: KeepAwakeFakeHelper(statuses: [.enabled]).dependencies()),
            floorEnabled: { true },
            rememberDuration: { _ in },
            resetSettings: {},
            thermalLevel: level
        )
    }

    func testTheLineReadsAsTheSpec() {
        XCTAssertEqual(KeepAwakeCopy.runningHotLine, "The Mac is running hot")
    }

    func testAnArmedModeOnASeriousOrCriticalMacSaysSo() {
        XCTAssertEqual(KeepAwakeCopy.heatLine(armed, level: .serious), "The Mac is running hot")
        XCTAssertEqual(KeepAwakeCopy.heatLine(armed, level: .critical), "The Mac is running hot")
    }

    func testANominalOrFairMacSaysNothing() {
        XCTAssertNil(KeepAwakeCopy.heatLine(armed, level: .nominal))
        XCTAssertNil(KeepAwakeCopy.heatLine(armed, level: .fair))
    }

    /// Only under the countdown: idle, the approval text and an end say nothing of the heat.
    func testOnlyAnArmedModeSaysSo() {
        for status in [KeepAwakeCopy.Status.idle, .approval, .ended(at: now, reason: .overheated)] {
            XCTAssertNil(KeepAwakeCopy.heatLine(status, level: .critical), "\(status)")
        }
    }

    @MainActor func testTheModelHoldsNominalUntilItReads() {
        let model = makeModel { .critical }
        XCTAssertEqual(model.thermal, .nominal)
        model.readThermal()
        XCTAssertEqual(model.thermal, .critical)
    }

    @MainActor func testEachReadTakesTheLevelAsItIsNow() {
        let source = LevelSource()
        let model = makeModel { source.level }
        source.level = .serious
        model.readThermal()
        XCTAssertEqual(model.thermal, .serious)
        source.level = .fair
        model.readThermal()
        XCTAssertEqual(model.thermal, .fair)
    }

    // MARK: - The guard waits for Apply (a mode armed before the update)

    func testTheGuardPendingLineReadsAsTheSpec() {
        XCTAssertEqual(KeepAwakeCopy.guardPendingText, "The heat guard starts with the next Apply.")
    }

    /// Armed, the helper's replies carry no `thermalGuard` (a 4.3.0 helper), the setting on.
    func testAnArmedHelperWithoutTheGuardSaysSoWhileTheSettingIsOn() {
        XCTAssertEqual(
            KeepAwakeCopy.guardPendingLine(armed, helperGuard: nil, settingOn: true),
            "The heat guard starts with the next Apply."
        )
    }

    func testWithTheSettingOffNothingIsSaid() {
        XCTAssertNil(KeepAwakeCopy.guardPendingLine(armed, helperGuard: nil, settingOn: false))
    }

    /// A helper whose replies carry the guard says nothing, whatever it holds: the model brings
    /// it to the setting.
    func testAHelperWithTheGuardSaysNothing() {
        XCTAssertNil(KeepAwakeCopy.guardPendingLine(armed, helperGuard: true, settingOn: true))
        XCTAssertNil(KeepAwakeCopy.guardPendingLine(armed, helperGuard: false, settingOn: true))
    }

    func testOnlyAnArmedModeSaysTheGuardIsPending() {
        for status in [KeepAwakeCopy.Status.idle, .approval, .ended(at: now, reason: .deadline)] {
            XCTAssertNil(KeepAwakeCopy.guardPendingLine(status, helperGuard: nil, settingOn: true), "\(status)")
        }
    }
}
