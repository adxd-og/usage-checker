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

    // MARK: A page move while closed (whole-branch review of 4.0, ruling R7)

    /// A provider that was the last open's page is switched off while the island is closed: the
    /// page lands, at rest, and no frame is asked for.
    func testAPageMoveWhileClosedLandsWithoutFrames() {
        let (driver, source) = make()
        let navigation = IslandNavigationModel()
        navigation.apply(.open(subject: "codex"), providers: ["claude", "codex"], reduceMotion: false, at: 1)
        XCTAssertEqual(navigation.page, .provider("codex"))

        let action = navigation.apply(.providersChanged, providers: ["claude", "grok"], reduceMotion: false, at: 2)
        if case .go = action, IslandTransition.pageMoveWantsFrames(phase: .closed) { driver.start() }

        XCTAssertEqual(navigation.page, .all)
        XCTAssertFalse(navigation.isMoving)
        XCTAssertEqual(navigation.frame, .resting(at: .all))
        XCTAssertEqual(source.starts, 0)
        XCTAssertFalse(driver.isRunning)
    }

    func testAPageMoveWantsFramesInEveryPhaseButClosed() {
        XCTAssertFalse(IslandTransition.pageMoveWantsFrames(phase: .closed))
        for phase: IslandTransition.Phase in [.opening, .open, .closing] {
            XCTAssertTrue(IslandTransition.pageMoveWantsFrames(phase: phase), "\(phase)")
        }
    }

    // MARK: Sleep

    func testSleepingDisplaysStopTheTicksAndWakingResumesThemWhileMotionIsPending() {
        let (driver, source) = make()
        driver.start()
        driver.displaysSlept()
        XCTAssertFalse(source.isRunning)
        driver.displaysWoke()
        XCTAssertTrue(source.isRunning)
        XCTAssertEqual(source.starts, 2)
    }

    func testWakingDoesNotResumeTicksWhenTheMotionEndedBeforeTheSleep() {
        let (driver, source) = make()
        driver.start()
        driver.stop()
        driver.displaysSlept()
        driver.displaysWoke()
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(source.starts, 1)
    }

    func testMotionAskedForWhileTheDisplaysSleepWaitsForTheWake() {
        let (driver, source) = make()
        driver.displaysSlept()
        driver.start()
        XCTAssertFalse(source.isRunning)
        driver.displaysWoke()
        XCTAssertTrue(source.isRunning)
    }

    // MARK: Event time

    func testAnEventNeverRunsBehindTheLastDrawnFrame() {
        XCTAssertEqual(IslandFrameDriver.eventTime(now: 10.000, lastFrame: 10.016), 10.016,
                       "a frame ahead of the event's clock: the event acts from what is drawn")
        XCTAssertEqual(IslandFrameDriver.eventTime(now: 10.5, lastFrame: 10.016), 10.5)
        XCTAssertEqual(IslandFrameDriver.eventTime(now: 10.5, lastFrame: nil), 10.5, "no frame yet")
    }
}
