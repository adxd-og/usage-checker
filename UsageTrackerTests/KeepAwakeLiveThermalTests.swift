import XCTest
@testable import Omelette

/// A `ProcessInfo` whose thermal state the test sets, so no test reads the Mac's own.
final class KeepAwakeStubProcessInfo: ProcessInfo, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState

    init(_ state: ProcessInfo.ThermalState) {
        self.state = state
        super.init()
    }

    func set(_ state: ProcessInfo.ThermalState) {
        lock.withLock { self.state = state }
    }

    override var thermalState: ProcessInfo.ThermalState {
        lock.withLock { state }
    }
}

/// Spec 2026-11-19 keep-awake thermal guard, § Daemon ("The daemon reads the thermal state
/// itself") and § What the user sees ("The app reads the level itself for this line"): the
/// helper and the app take the level through one function, `KeepAwakeReadings.liveThermal`.
final class KeepAwakeLiveThermalTests: XCTestCase {
    func testTheLiveReadingTakesEachStateAsThermalFromMapsIt() {
        let cases: [(ProcessInfo.ThermalState, KeepAwakeThermalLevel)] = [
            (.nominal, .nominal),
            (.fair, .fair),
            (.serious, .serious),
            (.critical, .critical),
        ]
        for (state, level) in cases {
            let info = KeepAwakeStubProcessInfo(state)
            XCTAssertEqual(KeepAwakeReadings.liveThermal(info), level, "raw state \(state.rawValue)")
            XCTAssertEqual(KeepAwakeReadings.liveThermal(info), KeepAwakeReadings.thermal(from: state), "raw state \(state.rawValue)")
        }
    }
}
