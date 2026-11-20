import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Daemon ("The daemon reads the thermal state
/// itself, as it reads the battery: on the change notification and on its one-minute tick"):
/// the daemon's observer of `ProcessInfo.thermalStateDidChangeNotification`, on a private
/// notification centre.
final class KeepAwakeThermalObserverTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    func testTheHandlerRunsOncePerThermalChange() {
        let center = NotificationCenter()
        let calls = Calls()
        let observer = KeepAwakeThermalObserver(center: center) { calls.add() }
        withExtendedLifetime(observer) {
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            XCTAssertEqual(calls.count, 1)
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            XCTAssertEqual(calls.count, 2)
        }
    }

    func testAnotherNotificationRunsNothing() {
        let center = NotificationCenter()
        let calls = Calls()
        let observer = KeepAwakeThermalObserver(center: center) { calls.add() }
        withExtendedLifetime(observer) {
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            center.post(name: Notification.Name("KeepAwakeThermalObserverTests.other"), object: nil)
            XCTAssertEqual(calls.count, 0)
        }
    }

    func testAReleasedObserverRunsNothing() {
        let center = NotificationCenter()
        let calls = Calls()
        var observer: KeepAwakeThermalObserver? = KeepAwakeThermalObserver(center: center) { calls.add() }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertNotNil(observer)
        observer = nil
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(calls.count, 1)
    }
}
