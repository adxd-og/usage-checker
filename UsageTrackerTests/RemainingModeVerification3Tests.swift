import Combine
import XCTest
@testable import Omelette

/// Independent verification of P4, part 3: the settings store, the two on-disk
/// propagation formats (`WidgetSnapshot`, `StatusSnapshot`), and the surfaces that
/// must stay byte-for-byte identical across the switch — `get_usage`'s prose,
/// `status.json`'s numbers, and `HistoryStore`'s records.
final class RemainingModeVerification3Tests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    // MARK: - SettingsStore.showsRemaining

    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }
    private var bag: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
        // Keeps `resetToDefaults()` off the shortcut the user recorded, which lives in
        // this same domain.
        MainActor.assumeIsolated { SettingsStore.shared.resetShortcuts = {} }
    }

    override func tearDown() {
        MainActor.assumeIsolated { SettingsStore.shared.resetShortcuts = SettingsStore.resetRecordedShortcuts }
        bag.removeAll()
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    @MainActor
    func testShowsRemainingDefaultsToFalse() {
        XCTAssertFalse(SettingsStore.Defaults.showsRemaining)
        SettingsStore.shared.resetToDefaults()
        XCTAssertFalse(SettingsStore.shared.showsRemaining)
        XCTAssertEqual(SettingsStore.shared.percentMode, .used)
    }

    /// What a relaunch reads: the key a fresh `init()` would read at process start.
    @MainActor
    func testShowsRemainingKeyRoundTripsThroughUserDefaults() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsStore.showsRemainingKey))
        settings.showsRemaining = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SettingsStore.showsRemainingKey))
    }

    @MainActor
    func testResetToDefaultsClearsShowsRemainingEvenWhenOn() {
        let settings = SettingsStore.shared
        settings.showsRemaining = true
        XCTAssertTrue(settings.showsRemaining)

        settings.resetToDefaults()

        XCTAssertFalse(settings.showsRemaining, "resetToDefaults() left the switch on")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: SettingsStore.showsRemainingKey))
    }

    /// Spec: "Changing the toggle re-renders immediately (the preference is
    /// observed)." Only true if flipping it sends `objectWillChange`.
    @MainActor
    func testTogglingShowsRemainingAnnouncesObjectWillChange() {
        let settings = SettingsStore.shared
        settings.showsRemaining = false
        let fired = expectation(description: "objectWillChange")
        settings.objectWillChange.sink { _ in fired.fulfill() }.store(in: &bag)
        settings.showsRemaining = true
        wait(for: [fired], timeout: 1)
    }

    // MARK: - WidgetSnapshot propagation (spec § "Propagation")

    func testWidgetSnapshotDecodesAnOlderFileWithNoKeyAsFalse() throws {
        let json = """
        {
          "services": [],
          "updatedAt": "2026-09-06T11:20:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(snapshot.showsRemaining)
        XCTAssertEqual(snapshot.mode, .used)
    }

    func testWidgetSnapshotDecodesTrueWhenTheKeyIsPresent() throws {
        let json = """
        {
          "services": [],
          "updatedAt": "2026-09-06T11:20:00Z",
          "showsRemaining": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.showsRemaining)
        XCTAssertEqual(snapshot.mode, .remaining)
    }

    func testWidgetSnapshotEncodeDecodeRoundTripPreservesTheFlag() throws {
        let bucket = WidgetBucket(id: "five_hour", label: "Session", percent: 42, kind: "session")
        let service = WidgetService(id: "claude", name: "Claude", icon: "sparkles", plan: "Max 5x", buckets: [bucket])
        let original = WidgetSnapshot(services: [service], updatedAt: Date(timeIntervalSince1970: 1_788_000_000), showsRemaining: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTripped = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(original))

        XCTAssertEqual(roundTripped, original)
        XCTAssertTrue(roundTripped.showsRemaining)
    }

    // MARK: - StatusSnapshot v2 propagation

    func testStatusSnapshotV2FileWithoutTheKeyDecodesAsFalseAndStaysVersion2() throws {
        let json = """
        {
          "version": 2,
          "updatedAt": "2026-09-06T11:20:00Z",
          "services": [],
          "agents": {"needsYou": 0, "working": 0, "sessions": []}
        }
        """
        let snapshot = try StatusFile.decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.version, 2)
        XCTAssertFalse(snapshot.showsRemaining)
        XCTAssertEqual(snapshot.percentMode, .used)
    }

    func testStatusSnapshotDecodesTrueWhenTheKeyIsPresent() throws {
        let json = """
        {
          "version": 2,
          "updatedAt": "2026-09-06T11:20:00Z",
          "services": [],
          "agents": {"needsYou": 0, "working": 0, "sessions": []},
          "showsRemaining": true
        }
        """
        let snapshot = try StatusFile.decoder.decode(StatusSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.showsRemaining)
        XCTAssertEqual(snapshot.percentMode, .remaining)
    }

    func testStatusSnapshotEncodeDecodeRoundTripPreservesTheFlagAndTheRawPercent() throws {
        let window = StatusSnapshot.Window(id: "extra_usage", label: "Extra usage credits", percent: 104)
        let service = StatusSnapshot.Service(id: "claude", name: "Claude", state: "ok", retained: false, windows: [window])
        let original = StatusSnapshot(
            version: 2, updatedAt: Date(timeIntervalSince1970: 1_788_000_000),
            services: [service], agents: .none, showsRemaining: true
        )

        let roundTripped = try StatusFile.decoder.decode(StatusSnapshot.self, from: StatusFile.encoder.encode(original))

        XCTAssertEqual(roundTripped, original)
        XCTAssertTrue(roundTripped.showsRemaining)
        // The number itself is untouched by the flag — 104%, unclamped, as written.
        XCTAssertEqual(roundTripped.services.first?.windows.first?.percent, 104)
    }

    // MARK: - StatusText / StatusLineText in both modes

    func testStatusTextSwitchesAWindowLineInBothModesIncludingUnclampedOverflow() {
        let window = StatusSnapshot.Window(id: "extra_usage", label: "Extra usage", percent: 104)

        let used = StatusText.windowText(window, mode: .used, now: now, calendar: calendar, locale: locale)
        let remaining = StatusText.windowText(window, mode: .remaining, now: now, calendar: calendar, locale: locale)

        XCTAssertEqual(used, "Extra usage 104%")
        XCTAssertEqual(remaining, "Extra usage 0% left")
    }

    /// A service with no windows falls back to its state text — untouched by mode.
    func testStatusTextServiceWithNoWindowsFallsBackToStateInBothModes() {
        let service = StatusSnapshot.Service(id: "codex", name: "Codex", state: "notSignedIn", retained: false, windows: [])
        let used = StatusText.serviceLine(service, width: 80, mode: .used, now: now, calendar: calendar, locale: locale)
        let remaining = StatusText.serviceLine(service, width: 80, mode: .remaining, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(used, remaining)
        XCTAssertTrue(used.contains("Sign in"), used)
    }

    func testStatusTextRetainedServiceSwitchesTheWindowNumberOnly() {
        let fetchedAt = now.addingTimeInterval(-3600)
        let window = StatusSnapshot.Window(id: "five_hour", label: "Session", percent: 80)
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true, retainedAt: fetchedAt, windows: [window]
        )
        let used = StatusText.serviceLine(service, width: 80, mode: .used, now: now, calendar: calendar, locale: locale)
        let remaining = StatusText.serviceLine(service, width: 80, mode: .remaining, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(used.contains("Session 80%"), used)
        XCTAssertTrue(remaining.contains("Session 20% left"), remaining)
        XCTAssertTrue(used.contains("last known"), used)
        XCTAssertTrue(remaining.contains("last known"), remaining)
    }

    /// Spec/ruling, exact: used mode is unclamped ("104%"), remaining mode clamps
    /// ("0% left"). Checked through the actual snapshot->percentMode path, not by
    /// calling `PercentDisplay` directly, so the wiring through `StatusSnapshot` is
    /// what's under test here (`RemainingModeVerificationTests` already pins the rule
    /// itself).
    func testStatusLineTextIsUnclampedInUsedAndClampedInRemainingThroughTheSnapshot() {
        let window = StatusSnapshot.Window(id: "five_hour", label: "Session", percent: 104, kind: "session")
        let usedSnapshot = StatusSnapshot(
            version: 2, updatedAt: now,
            services: [StatusSnapshot.Service(id: "claude", name: "Claude", state: "ok", retained: false, windows: [window])],
            agents: .none, showsRemaining: false
        )
        let remainingSnapshot = StatusSnapshot(
            version: 2, updatedAt: now,
            services: [StatusSnapshot.Service(id: "claude", name: "Claude", state: "ok", retained: false, windows: [window])],
            agents: .none, showsRemaining: true
        )

        XCTAssertEqual(StatusLineText.render(snapshot: usedSnapshot, now: now), "◐ 104%")
        XCTAssertEqual(StatusLineText.render(snapshot: remainingSnapshot, now: now), "◐ 0% left")
    }

    // MARK: - What must never move: get_usage prose, status.json numbers, history

    /// Spec § "Surfaces that do not switch": "`get_usage` numbers (machine contract
    /// stays 'used')"; Decision 9: the MCP tools do not change at all. Two
    /// snapshots differing only in `showsRemaining` must produce identical prose.
    func testMCPUsageProseIsIdenticalRegardlessOfDisplayMode() {
        let window = StatusSnapshot.Window(
            id: "five_hour", label: "Session", percent: 63,
            resetsAt: now.addingTimeInterval(3600), kind: "session"
        )
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, plan: "Max 5x",
            windows: [window], todayCost: 4.2
        )
        let used = StatusSnapshot(version: 2, updatedAt: now, services: [service], agents: .none, showsRemaining: false)
        let remaining = StatusSnapshot(version: 2, updatedAt: now, services: [service], agents: .none, showsRemaining: true)

        let usedProse = MCPSummary.usage(snapshot: used, now: now, calendar: calendar, locale: locale)
        let remainingProse = MCPSummary.usage(snapshot: remaining, now: now, calendar: calendar, locale: locale)

        XCTAssertEqual(usedProse, remainingProse, "get_usage must read the same regardless of the display switch")
        XCTAssertTrue(usedProse.contains("session 63%"), usedProse)
    }

    /// Spec § "Propagation": "Both files keep their numbers as *used*; only the
    /// flag travels." Built through `StatusFileWriter.build`, independent fixture
    /// from the executor's (a retained service with a cost entry).
    func testStatusFileWriterNumbersAreIdenticalAcrossModesOnlyTheFlagDiffers() {
        let service = Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "five_hour", label: "Session", percent: 71, kind: .session)],
            state: .error, at: now
        )
        let costs = ["codex": StatusFileWriter.CostEntry(todayCost: 1.5, weekCost: 9.0, todayTokens: 1000)]

        let used = StatusFileWriter.build(services: [service], costs: costs, agents: .none, now: now, mode: .used)
        let remaining = StatusFileWriter.build(services: [service], costs: costs, agents: .none, now: now, mode: .remaining)

        XCTAssertFalse(used.showsRemaining)
        XCTAssertTrue(remaining.showsRemaining)
        XCTAssertEqual(used.services.first?.windows.map(\.percent), remaining.services.first?.windows.map(\.percent))
        XCTAssertEqual(used.services.first?.windows.map(\.percent), [71])
        XCTAssertEqual(used.services.first?.todayCost, remaining.services.first?.todayCost)
        XCTAssertEqual(used.services.first?.retained, remaining.services.first?.retained)
    }

    /// Spec § "Surfaces that do not switch": "`HistoryStore` records" are untouched.
    /// `HistoryRecord.init(from:)` takes no mode at all, so flipping the app-wide
    /// switch around the moment of construction must not leak into a stored value.
    @MainActor
    func testHistoryRecordCapturesRawUtilizationRegardlessOfTheSwitch() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: 47, kind: .session)]
        )

        SettingsStore.shared.showsRemaining = false
        let whileUsed = HistoryRecord(from: service, at: now)
        SettingsStore.shared.showsRemaining = true
        let whileRemaining = HistoryRecord(from: service, at: now)
        SettingsStore.shared.showsRemaining = false

        XCTAssertEqual(whileUsed.fiveHourPercent, 47)
        XCTAssertEqual(whileRemaining.fiveHourPercent, 47, "the toggle must not invert what gets recorded")
        XCTAssertEqual(whileUsed.bucketPercents, whileRemaining.bucketPercents)
    }
}
