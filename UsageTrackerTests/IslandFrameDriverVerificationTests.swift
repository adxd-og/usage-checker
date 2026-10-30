import XCTest
@testable import Omelette

/// A frame source the test fires by hand, counting how the driver treats it.
@MainActor
private final class CountingFrameSource: IslandFrameSource {
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

    func fire(_ time: TimeInterval) { tick?(time) }
}

/// Verification of `IslandFrameDriver` against notch-island spec 2026-10-29 § 3.8 (collapsed,
/// the island adds no timers and no wake-ups) and plan M16 (frames pause while the displays
/// sleep, resume at the wake only if motion is pending, and stop when the window closes).
@MainActor
final class IslandFrameDriverVerificationTests: XCTestCase {
    private func make() -> (IslandFrameDriver, CountingFrameSource) {
        let source = CountingFrameSource()
        return (IslandFrameDriver(source: source), source)
    }

    func testAWakeWithoutASleepDoesNotRestartRunningFrames() {
        let (driver, source) = make()
        driver.start()
        driver.displaysWoke()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 0)
        XCTAssertTrue(driver.isRunning)
    }

    func testASleepWithNoMotionWantedTouchesNothingAndTheWakeStartsNothing() {
        let (driver, source) = make()
        driver.displaysSlept()
        driver.displaysWoke()
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(source.stops, 0)
        XCTAssertFalse(driver.isRunning)
    }

    func testTwoSleepsAndOneWakeStillResumePendingMotion() {
        let (driver, source) = make()
        driver.start()
        driver.displaysSlept()
        driver.displaysSlept()
        XCTAssertEqual(source.stops, 1)
        driver.displaysWoke()
        XCTAssertTrue(driver.isRunning)
        XCTAssertEqual(source.starts, 2)
    }

    func testTheMotionEndingWhileTheDisplaysSleepKeepsTheFramesOffAtTheWake() {
        let (driver, source) = make()
        driver.start()
        driver.displaysSlept()
        driver.stop()
        driver.displaysWoke()
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(source.starts, 1)
        driver.start()
        XCTAssertTrue(driver.isRunning, "a later motion runs as usual")
        XCTAssertEqual(source.starts, 2)
    }

    func testFramesAfterAWakeReachTheSameHandlerAndNoneComeWhileAsleep() {
        let (driver, source) = make()
        var ticks: [TimeInterval] = []
        driver.onFrame = { ticks.append($0) }
        driver.start()
        source.fire(1)
        driver.displaysSlept()
        source.fire(2)
        driver.displaysWoke()
        source.fire(3)
        driver.stop()
        source.fire(4)
        XCTAssertEqual(ticks, [1, 3])
    }

    func testTheWindowClosingStopsFramesForGoodEvenWhileAwake() {
        let (driver, source) = make()
        driver.start()
        driver.stop()  // IslandController.islandWillClose
        driver.displaysSlept()
        driver.displaysWoke()
        XCTAssertFalse(driver.isRunning)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 1)
    }
}
