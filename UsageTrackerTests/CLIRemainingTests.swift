import XCTest
@testable import Omelette

/// `status.json` and the two things that render it. The numbers in the file stay
/// "used" — it is a machine contract and `omelette status --json` prints it
/// verbatim — and only the flag says which way the human-readable lines count.
/// Spec § "Propagation" and § "Surfaces that do not switch".
final class CLIRemainingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIRemainingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func window(
        _ id: String, _ label: String, _ percent: Double, resetsIn: TimeInterval? = nil, kind: String? = nil
    ) -> StatusSnapshot.Window {
        StatusSnapshot.Window(
            id: id, label: label, percent: percent,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind
        )
    }

    private func snapshot(
        windows: [StatusSnapshot.Window], todayCost: Double? = nil, showsRemaining: Bool
    ) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: "Max 5x", windows: windows, todayCost: todayCost, weekCost: nil,
                    todayTokens: nil, apiEquivalent: true
                ),
            ],
            agents: .none,
            showsRemaining: showsRemaining
        )
    }

    // MARK: - The file

    func testAFileWrittenBeforeTheSwitchExistedStillOpens() throws {
        // A hand-written v2 file with no showsRemaining key: exactly what 2.4.1 wrote.
        let json = """
        {
          "agents" : { "needsYou" : 0, "sessions" : [], "working" : 0 },
          "services" : [],
          "updatedAt" : "2026-09-06T11:20:00Z",
          "version" : 2
        }
        """
        let url = directory.appendingPathComponent("status.json")
        try Data(json.utf8).write(to: url)
        let snapshot = try XCTUnwrap(StatusFile.load(from: url), "an added key must not make an old file unreadable")
        XCTAssertFalse(snapshot.showsRemaining)
        XCTAssertEqual(snapshot.percentMode, .used)
    }

    func testTheFlagRoundTripsThroughTheFile() async throws {
        let url = directory.appendingPathComponent("status.json")
        let writer = StatusFileWriter(fileURL: url, minimumInterval: 0)
        let built = StatusFileWriter.build(
            services: [Fixture.snapshot(
                id: "claude",
                buckets: [Fixture.bucket(id: "five_hour", label: "Session", percent: 42, kind: .session)]
            )],
            costs: [:], agents: .none, now: now, calendar: calendar, locale: locale, mode: .remaining
        )
        XCTAssertTrue(built.showsRemaining)
        XCTAssertEqual(built.services.first?.windows.first?.percent, 42, "the numbers stay used")

        _ = await writer.write(built, now: now)
        let read = try XCTUnwrap(StatusFile.load(from: url))
        XCTAssertTrue(read.showsRemaining)
        XCTAssertEqual(read.services.first?.windows.first?.percent, 42)
    }

    func testTheWriterDefaultsToCountingUp() {
        let built = StatusFileWriter.build(
            services: [Fixture.snapshot(id: "claude", buckets: [])],
            costs: [:], agents: .none, now: now
        )
        XCTAssertFalse(built.showsRemaining)
    }

    // MARK: - omelette status

    func testTheStatusLinesSpellOutWhatIsLeft() {
        let text = StatusText.render(
            snapshot: snapshot(windows: [window("five_hour", "Session", 42, resetsIn: 100 * 60, kind: "session")],
                               todayCost: 4.2, showsRemaining: true),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, "Claude  Session 58% left, resets in 1h 40m (13:00) · $4.20 today\n")
    }

    func testTheStatusLinesAreUnchangedWhenTheSwitchIsOff() {
        let text = StatusText.render(
            snapshot: snapshot(windows: [window("five_hour", "Session", 42, resetsIn: 100 * 60, kind: "session")],
                               todayCost: 4.2, showsRemaining: false),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, "Claude  Session 42%, resets in 1h 40m (13:00) · $4.20 today\n")
    }

    func testAWindowPastItsLimitHasNothingLeftInTheTerminalEither() {
        let text = StatusText.render(
            snapshot: snapshot(windows: [window("extra_usage", "Spend limit", 137)], showsRemaining: true),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, "Claude  Spend limit 0% left\n")
    }

    func testCountingUpTheTerminalStillPrintsAReadingPastTheLimit() {
        // The file records what is true and the terminal has no arc to overflow, so
        // "104%" survives counting up. Only the countdown clamps: there is nothing
        // below "0% left".
        let text = StatusText.render(
            snapshot: snapshot(windows: [window("extra_usage", "Spend limit", 104.2)], showsRemaining: false),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, "Claude  Spend limit 104%\n")
    }

    // MARK: - omelette statusline

    func testTheStatusLineSaysWhatIsLeft() {
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(windows: [window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session")],
                                   todayCost: 4.2, showsRemaining: true),
                now: now
            ),
            "◐ 58% left · resets in 1h 10m · $4.20 today"
        )
    }

    func testTheStatusLineIsUnchangedWhenTheSwitchIsOff() {
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(windows: [window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session")],
                                   todayCost: 4.2, showsRemaining: false),
                now: now
            ),
            "◐ 42% · resets in 1h 10m · $4.20 today"
        )
    }

    func testTheStatusLineStillLeadsWithTheFullestWindow() throws {
        // Which window the line speaks for is ranked by usage, in both modes.
        let snap = snapshot(
            windows: [window("a", "Quiet", 5, kind: "weekly"), window("b", "Busy", 91, kind: "weekly")],
            showsRemaining: true
        )
        let service = try XCTUnwrap(snap.service(id: "claude"))
        XCTAssertEqual(StatusLineText.headlineWindow(service)?.id, "b")
        XCTAssertEqual(StatusLineText.render(snapshot: snap, now: now), "◐ 9% left")
    }
}
