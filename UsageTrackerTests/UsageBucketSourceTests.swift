import XCTest
@testable import Omelette

/// The source tag on a window (spec 2026-11-02 Claude limits from the status line,
/// § Source tag): `UsageBucket.source` and the reading's `asOf`, Codable-additive. A
/// `last-known.json` written before them opens with no source, which reads as the
/// provider's own fetch; a window the status line fed keeps its tag and its time through
/// a relaunch; an untagged window writes neither key; and a source a later build adds
/// reads as none here rather than losing the whole file (session ruling 6).
final class UsageBucketSourceTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageBucketSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `last-known.json` as 4.0.0 writes Claude: no window carries a source.
    private let claudeFrom400 = """
    {"claude": {"displayName": "Claude", "icon": "sparkles", "plan": "Max 20x", "order": 0,
      "fetchedAt": "2026-09-06T11:00:00Z", "buckets": [
        {"id": "five_hour", "label": "Current session", "utilization": 23, "resetsAt": "2026-09-06T14:00:00Z", "kind": "session"},
        {"id": "seven_day", "label": "All models", "utilization": 41, "resetsAt": "2026-09-10T18:40:00Z", "kind": "weekly"}
      ]}}
    """

    func testAFileFromBeforeTheTagOpensWithNoSource() async throws {
        try Data(claudeFrom400.utf8).write(to: fileURL)

        let loaded = await LastKnownStore(fileURL: fileURL).load()

        let entry = try XCTUnwrap(loaded["claude"])
        XCTAssertEqual(entry.buckets.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(entry.buckets.map(\.utilization), [23, 41])
        XCTAssertEqual(entry.buckets.map(\.source), [nil, nil], "no source reads as the provider's own fetch")
        XCTAssertEqual(entry.buckets.map(\.asOf), [nil, nil])
    }

    func testAStatusLineWindowKeepsItsTagAndTimeThroughARelaunch() async throws {
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [
                Fixture.bucket(
                    id: "five_hour", label: "Current session", percent: 23.5,
                    resetsAt: Date(timeIntervalSince1970: 1_788_703_200), kind: .session,
                    source: .statusLine, asOf: now.addingTimeInterval(-60)
                ),
                Fixture.bucket(
                    id: "seven_day_opus", label: "Opus only", percent: 12,
                    resetsAt: Date(timeIntervalSince1970: 1_789_065_600), kind: .modelSpecific
                ),
            ],
            at: now
        )

        await LastKnownStore(fileURL: fileURL).remember([claude])
        let loaded = await LastKnownStore(fileURL: fileURL).load()

        let entry = try XCTUnwrap(loaded["claude"])
        XCTAssertEqual(entry.buckets, claude.buckets)
        XCTAssertEqual(entry.buckets.map(\.source), [.statusLine, nil])
        XCTAssertEqual(entry.buckets.map(\.asOf), [now.addingTimeInterval(-60), nil])
    }

    /// Absent, never `null`: an untagged window is what 4.0.0 wrote, key for key.
    func testAnUntaggedWindowWritesNoSourceKey() throws {
        let untagged = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Fixture.bucket(id: "five_hour", percent: 23, kind: .session))
        ) as? [String: Any])
        let tagged = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Fixture.bucket(
                id: "five_hour", percent: 23, kind: .session, source: .statusLine, asOf: now
            ))
        ) as? [String: Any])

        XCTAssertNil(untagged["source"])
        XCTAssertNil(untagged["asOf"])
        XCTAssertEqual(tagged["source"] as? String, "statusLine")
        XCTAssertNotNil(tagged["asOf"])
    }

    /// A later build's source: this one reads the window with no source and keeps every
    /// provider's numbers. A strict enum would fail the whole file, and `LastKnownStore`
    /// treats a file that fails as empty.
    func testASourceALaterBuildAddsReadsAsNoneAndLosesNothing() async throws {
        let fromLater = """
        {"claude": {"displayName": "Claude", "icon": "sparkles", "plan": "Max 20x", "order": 0,
          "fetchedAt": "2026-09-06T11:00:00Z", "buckets": [
            {"id": "five_hour", "label": "Current session", "utilization": 23, "resetsAt": "2026-09-06T14:00:00Z",
             "kind": "session", "source": "socket", "asOf": "2026-09-06T11:19:00Z"}
          ]},
         "antigravity": {"displayName": "Antigravity", "icon": "sparkles", "plan": "Antigravity Pro", "order": 1,
          "fetchedAt": "2026-09-06T10:00:00Z", "buckets": [
            {"id": "antigravity_gemini", "label": "Gemini models", "utilization": 62, "resetsAt": "2026-09-06T15:00:00Z", "kind": "other"}
          ]}}
        """
        try Data(fromLater.utf8).write(to: fileURL)

        let loaded = await LastKnownStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded.keys.sorted(), ["antigravity", "claude"], "no provider lost")
        let claude = try XCTUnwrap(loaded["claude"]?.buckets.first)
        XCTAssertEqual(claude.utilization, 23)
        XCTAssertNil(claude.source, "a source this build does not know is none")
        XCTAssertEqual(claude.asOf, Date(timeIntervalSince1970: 1_788_693_540))
        XCTAssertEqual(loaded["antigravity"]?.buckets.first?.utilization, 62)
    }

    /// The spelling `status.json` and history carry.
    func testTheSourcesAreSpelledOauthAndStatusLine() {
        XCTAssertEqual(ReadingSource.oauth.rawValue, "oauth")
        XCTAssertEqual(ReadingSource.statusLine.rawValue, "statusLine")
        XCTAssertEqual(ReadingSource(rawValue: "statusLine"), .statusLine)
        XCTAssertNil(ReadingSource(rawValue: "status_line"))
    }
}
