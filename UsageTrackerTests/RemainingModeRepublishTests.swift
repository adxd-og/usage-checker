import XCTest
@testable import Omelette

/// Spec § "Propagation" — "Changing the toggle re-renders immediately (the
/// preference is observed), republishes the widget snapshot and status.json."
///
/// The two files are written side by side from the same poll and neither is derived
/// from the other, so what is worth pinning is that one switch decides both and that
/// neither of them touches the numbers.
final class RemainingModeRepublishTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }
    /// 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    private var service: ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            ],
            at: now
        )
    }

    @MainActor
    func testOneSwitchDecidesWhatBothPublishedFilesSay() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        let mode = settings.percentMode

        let widget = WidgetBridge.snapshot(from: [service], at: now, mode: mode)
        let status = StatusFileWriter.build(
            services: [service], costs: [:], agents: .none, now: now, mode: mode
        )

        XCTAssertTrue(widget.showsRemaining)
        XCTAssertTrue(status.showsRemaining)
        XCTAssertEqual(widget.mode, status.percentMode, "the two files must never disagree about the mode")
    }

    @MainActor
    func testTurningTheSwitchOffPutsBothFilesBack() {
        let settings = SettingsStore.shared
        settings.showsRemaining = false
        let mode = settings.percentMode

        XCTAssertFalse(WidgetBridge.snapshot(from: [service], at: now, mode: mode).showsRemaining)
        XCTAssertFalse(
            StatusFileWriter.build(services: [service], costs: [:], agents: .none, now: now, mode: mode)
                .showsRemaining
        )
    }

    @MainActor
    func testRepublishingChangesNoNumberInEitherFile() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        let mode = settings.percentMode

        let widget = WidgetBridge.snapshot(from: [service], at: now, mode: mode)
        let status = StatusFileWriter.build(
            services: [service], costs: [:], agents: .none, now: now, mode: mode
        )

        XCTAssertEqual(widget.services.first?.buckets.map(\.percent), [42, 18])
        XCTAssertEqual(status.services.first?.windows.map(\.percent), [42, 18])
    }

    /// A republish arriving inside the writer's two-second throttle must not be the
    /// one that gets lost: the trailing write is what carries it to disk.
    func testARepublishInsideTheThrottleStillHasAWayToDisk() {
        XCTAssertFalse(
            StatusFileWriter.shouldWrite(lastWriteAt: now, now: now.addingTimeInterval(0.2)),
            "a write this soon is swallowed, which is what schedules the trailing one"
        )
        XCTAssertTrue(
            StatusFileWriter.shouldWrite(lastWriteAt: now, now: now.addingTimeInterval(2))
        )
    }
}
