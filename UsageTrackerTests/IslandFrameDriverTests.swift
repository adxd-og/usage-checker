import XCTest
@testable import Omelette

/// A frame source the test fires by hand, in place of the display link.
@MainActor
private final class FakeFrameSource: IslandFrameSource {
    private(set) var starts = 0
    private(set) var stops = 0
    private var tick: (@MainActor (TimeInterval) -> Void)?

    var isRunning: Bool { tick != nil }

    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void) {
        starts += 1
        self.tick = tick
    }

    func stop() {
        stops += 1
        tick = nil
    }

    func fire(_ time: TimeInterval) {
        tick?(time)
    }
}

/// Notch-island spec 2026-10-29 § 3.8 (no timers or wake-ups collapsed) and § 3.2: the
/// island's frame clock ticks only while motion is wanted. A fake frame source stands in for
/// the display link.
@MainActor
final class IslandFrameDriverTests: XCTestCase {
    private func make() -> (IslandFrameDriver, FakeFrameSource) {
        let source = FakeFrameSource()
        return (IslandFrameDriver(source: source), source)
    }

    func testTheDriverTicksOnlyWhileMotionIsWanted() {
        let (driver, source) = make()
        var ticks: [TimeInterval] = []
        driver.onFrame = { ticks.append($0) }
        XCTAssertFalse(driver.isRunning)
        driver.start()
        XCTAssertTrue(driver.isRunning)
        source.fire(1.0)
        driver.stop()
        XCTAssertFalse(driver.isRunning)
        source.fire(2.0)
        XCTAssertEqual(ticks, [1.0])
    }

    func testAStartWhileTickingDoesNotRestartTheSource() {
        let (driver, source) = make()
        driver.start()
        driver.start()
        XCTAssertEqual(source.starts, 1)
    }

    func testAStopEndsTheTicksAndASecondStopChangesNothing() {
        let (driver, source) = make()
        driver.start()
        driver.stop()
        driver.stop()
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(source.isRunning)
    }
}
