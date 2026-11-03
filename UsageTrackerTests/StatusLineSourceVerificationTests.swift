import XCTest
@testable import Omelette

/// Verification of the source tag (spec 2026-11-02 Claude limits from the status line,
/// § Design › Source tag): old records decode, a source nobody knows reads as none and
/// loses nothing else, status.json / MCP / history / the page line say what the spec lists.
final class StatusLineSourceVerificationTests: XCTestCase {
    private var directory: URL!

    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineSourceVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - last-known.json

    /// Every spelling of `source` a file can hold: the two known, an unknown word, a
    /// number, null, an empty string. Whatever it is, the window's other keys (window
    /// length, credit pool, asOf) and the other provider survive.
    func testEverySpellingOfSourceLeavesTheRestOfTheFileOpen() async throws {
        let spellings = [
            (#""source": "oauth""#, ReadingSource.oauth as ReadingSource?),
            (#""source": "statusLine""#, .statusLine),
            (#""source": "socket""#, nil),
            (#""source": 7"#, nil),
            (#""source": null"#, nil),
            (#""source": """#, nil),
            (#""source": ["statusLine"]"#, nil),
            (#""x": 1"#, nil),
        ]
        for (index, spelled) in spellings.enumerated() {
            let file = """
            {"claude": {"displayName": "Claude", "icon": "sparkles", "plan": "Max 20x", "order": 0,
              "fetchedAt": "2026-09-06T11:00:00Z", "buckets": [
                {"id": "five_hour", "label": "Current session", "utilization": 23.5, "resetsAt": "2026-09-06T14:00:00Z",
                 "kind": "session", "windowLength": 18000, "asOf": "2026-09-06T11:19:00Z", \(spelled.0)},
                {"id": "iguana_necktie", "label": "Cloud session credits", "utilization": 92.3, "resetsAt": "2026-11-05T07:59:00Z",
                 "kind": "other", "credit": {"usedDollars": 230.9, "limitDollars": 250}}
              ]},
             "grok": {"displayName": "Grok", "icon": "sparkles", "plan": "Grok", "order": 1,
              "fetchedAt": "2026-09-06T10:00:00Z", "buckets": [
                {"id": "grok_day", "label": "Day", "utilization": 5, "resetsAt": "2026-09-07T10:00:00Z", "kind": "other"}
              ]}}
            """
            let url = directory.appendingPathComponent("last-known-\(index).json")
            try Data(file.utf8).write(to: url)

            let loaded = await LastKnownStore(fileURL: url).load()

            XCTAssertEqual(loaded.keys.sorted(), ["claude", "grok"], "case \(index): \(spelled.0)")
            let five = try XCTUnwrap(loaded["claude"]?.buckets.first, "case \(index)")
            XCTAssertEqual(five.source, spelled.1, "case \(index): \(spelled.0)")
            XCTAssertEqual(five.utilization, 23.5)
            XCTAssertEqual(five.windowLength, 18000)
            XCTAssertEqual(five.asOf, Date(timeIntervalSince1970: 1_788_693_540))
            XCTAssertEqual(loaded["claude"]?.buckets.last?.credit, CreditPool(usedDollars: 230.9, limitDollars: 250))
        }
    }

    /// A tagged window written by this build and read by it: tag, time, and the
    /// untagged window beside it.
    func testATaggedWindowRoundTripsBesideAnUntaggedOne() async throws {
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 23.5,
                               resetsAt: Date(timeIntervalSince1970: 1_788_703_200), kind: .session,
                               source: .statusLine, asOf: ago(60)),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 41,
                               resetsAt: Date(timeIntervalSince1970: 1_789_065_600), kind: .weekly),
            ],
            at: now
        )
        let url = directory.appendingPathComponent("last-known.json")
        await LastKnownStore(fileURL: url).remember([claude])

        let loaded = await LastKnownStore(fileURL: url).load()

        XCTAssertEqual(loaded["claude"]?.buckets.map(\.source), [.statusLine, nil])
        XCTAssertEqual(loaded["claude"]?.buckets.map(\.asOf), [ago(60), nil])
        XCTAssertEqual(loaded["claude"]?.buckets.map(\.utilization), [23.5, 41])
    }

    // MARK: - history.jsonl

    /// A log with a line from 4.0.0, a tagged line, and a line from a later build whose
    /// `bucketSources` names a source this build does not know: all three are records.
    func testHistoryKeepsEveryLineWhateverItsSources() async throws {
        let lines = [
            #"{"id":"7C6DEC8E-0F71-4E27-9C2C-1F7A1E9A0001","timestamp":"2026-09-06T10:00:00Z","fiveHourPercent":20.0,"sevenDayPercent":40.0,"bucketPercents":{"five_hour":20.0,"seven_day":40.0}}"#,
            #"{"id":"7C6DEC8E-0F71-4E27-9C2C-1F7A1E9A0002","timestamp":"2026-09-06T10:30:00Z","fiveHourPercent":23.5,"bucketPercents":{"five_hour":23.5,"seven_day":41.0},"bucketSources":{"five_hour":"statusLine"}}"#,
            #"{"id":"7C6DEC8E-0F71-4E27-9C2C-1F7A1E9A0003","timestamp":"2026-09-06T11:00:00Z","fiveHourPercent":24.0,"bucketPercents":{"five_hour":24.0},"bucketSources":{"five_hour":"carrierPigeon","seven_day":"oauth"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("history.jsonl"))
        let fixed = now

        let records = await HistoryStore(directory: directory, now: { fixed }).all(service: "claude")

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0.source(for: "five_hour") }, [.oauth, .statusLine, .oauth])
        XCTAssertEqual(records.map { $0.source(for: "seven_day") }, [.oauth, .oauth, .oauth])
        XCTAssertEqual(records.map { $0.percent(for: "five_hour") }, [20, 23.5, 24])
    }

    /// Two buckets with the same id would collide in the dictionary; the record must not
    /// trap, and an untagged one beside a tagged one does not erase the tag.
    func testARecordWithRepeatedBucketIDsDoesNotTrap() {
        let s = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", percent: 1, source: .statusLine, asOf: ago(1)),
                Fixture.bucket(id: "five_hour", percent: 2, source: .statusLine, asOf: ago(1)),
                Fixture.bucket(id: "seven_day", percent: 3),
            ]
        )
        let record = HistoryRecord(from: s, at: now)
        XCTAssertEqual(record.bucketSources, ["five_hour": "statusLine"])
    }

    // MARK: - status.json

    /// A retained Claude that the status line fed: the file says retained, and the fed
    /// window carries its own source and time next to the service's; the OAuth windows
    /// carry neither key.
    func testStatusFileOfARetainedFedClaude() throws {
        var claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 23.5,
                               resetsAt: Date(timeIntervalSince1970: 1_788_703_200), kind: .session,
                               source: .statusLine, asOf: ago(60)),
                Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12,
                               resetsAt: Date(timeIntervalSince1970: 1_789_065_600), kind: .modelSpecific),
            ],
            state: .notSignedIn, at: ago(3 * 3600)
        )
        claude.isCarriedOver = true

        let file = StatusFileWriter.build(services: [claude], costs: [:], agents: .none, now: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: StatusFile.encoder.encode(file)) as? [String: Any])
        let service = try XCTUnwrap((object["services"] as? [[String: Any]])?.first)
        let windows = try XCTUnwrap(service["windows"] as? [[String: Any]])

        XCTAssertEqual(service["retained"] as? Bool, true)
        XCTAssertEqual(windows.first?["source"] as? String, "statusLine")
        XCTAssertEqual(windows.first?["asOf"] as? String, "2026-09-06T11:19:00Z")
        XCTAssertFalse(windows.last?.keys.contains("source") ?? true)
        XCTAssertFalse(windows.last?.keys.contains("asOf") ?? true)
        XCTAssertEqual(file.version, 2)
        // And the file reads back through the shared decoder.
        let back = try StatusFile.decoder.decode(StatusSnapshot.self, from: StatusFile.encoder.encode(file))
        XCTAssertEqual(back.services.first?.windows.map(\.source), ["statusLine", nil])
    }

    // MARK: - MCP paragraph

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func service(retained: Bool, fiveFed: Bool, fivePercent: Double, weekPercent: Double) -> StatusSnapshot {
        StatusSnapshot(
            version: 2, updatedAt: now,
            services: [StatusSnapshot.Service(
                id: "claude", name: "Claude", state: retained ? "notSignedIn" : "ok", retained: retained,
                retainedAt: retained ? ago(3600) : nil, plan: "Max 5x",
                windows: [
                    StatusSnapshot.Window(
                        id: "five_hour", label: "Session", percent: fivePercent,
                        resetsAt: now.addingTimeInterval(100 * 60), kind: "session",
                        source: fiveFed ? "statusLine" : nil, asOf: fiveFed ? ago(60) : nil
                    ),
                    StatusSnapshot.Window(
                        id: "seven_day", label: "Weekly", percent: weekPercent,
                        resetsAt: now.addingTimeInterval(4 * 86_400), kind: "weekly"
                    ),
                ],
                todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: nil
            )],
            agents: .none
        )
    }

    /// The advice dates the worst window by its own reading only when that window is the
    /// fed one: here the weekly window is the worst and OAuth's, so it is "last seen" at
    /// the provider's last good fetch (10:20), not at the fed session window's 11:19.
    func testTheAdviceDatesTheWorstWindowByItsOwnSource() {
        let text = MCPSummary.usage(
            snapshot: service(retained: true, fiveFed: true, fivePercent: 30, weekPercent: 80),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(text.contains("weekly window was 80% used when last seen at 10:20"), text)
        XCTAssertTrue(text.contains("session 30% from Claude Code at 11:19"), text)
        XCTAssertFalse(text.contains("weekly 80% from Claude Code"), text)
    }

    /// A live provider's unfed windows say nothing about a source.
    func testAnUnfedLiveProviderSaysNothingAboutWhereItCameFrom() {
        let text = MCPSummary.usage(
            snapshot: service(retained: false, fiveFed: false, fivePercent: 30, weekPercent: 40),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertFalse(text.contains("from Claude Code"), text)
        XCTAssertFalse(text.lowercased().contains("oauth"), text)
    }

    // MARK: - The page line

    /// Several fed windows with different times: the page is as old as the newest.
    func testThePageIsAsOldAsTheNewestFedWindow() {
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(id: "five_hour", percent: 1, kind: .session, source: .statusLine, asOf: ago(300)),
                Fixture.bucket(id: "seven_day", percent: 2, kind: .weekly, source: .statusLine, asOf: ago(120)),
                Fixture.bucket(id: "seven_day_opus", percent: 3, kind: .modelSpecific),
            ],
            state: .error, at: ago(7200)
        )
        XCTAssertEqual(
            PopoverCopy.metaLine(service: claude, fetchedAt: ago(7200), now: now),
            "Claude Max 20x · Updated 2m ago from Claude Code"
        )
    }
}
