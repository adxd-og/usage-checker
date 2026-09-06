import XCTest
@testable import Omelette

/// The shape of `status.json`. Both ends of it are in this bundle — the app writes it
/// and the CLI reads it from the same declarations — so the round trip is the contract.
final class StatusSnapshotTests: XCTestCase {
    private var directory: URL!

    /// 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample() -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: "claude",
                    name: "Claude",
                    state: "ok",
                    retained: false,
                    retainedAt: nil,
                    plan: "Max 5x",
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: 42,
                            resetsAt: now.addingTimeInterval(100 * 60), kind: "session"
                        ),
                    ],
                    todayCost: 4.2,
                    weekCost: 31.7,
                    todayTokens: 1_234_567,
                    apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(
                needsYou: 1, working: 2,
                sessions: [
                    StatusSnapshot.Session(
                        id: "claude:abc", project: "Usage tracker",
                        state: "needsYou", activity: "Remove build artifacts"
                    ),
                ]
            )
        )
    }

    func testTheFileRoundTrips() throws {
        let url = directory.appendingPathComponent("status.json")
        let data = try StatusFile.encoder.encode(sample())
        try data.write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        XCTAssertEqual(loaded, sample())
    }

    func testDatesAreISO8601AndAbsentValuesAreAbsentKeys() throws {
        let text = String(decoding: try StatusFile.encoder.encode(sample()), as: UTF8.self)

        XCTAssertTrue(text.contains("\"updatedAt\" : \"2026-09-06T11:20:00Z\""), text)
        XCTAssertFalse(text.contains("retainedAt"), "a live service stamps nothing")
        XCTAssertFalse(text.contains("\\/"), "escaped slashes make the file unreadable")
    }

    func testAFileFromAnotherVersionIsNoFileAtAll() throws {
        let url = directory.appendingPathComponent("status.json")
        var future = sample()
        future.version = 99
        try StatusFile.encoder.encode(future).write(to: url)

        XCTAssertNil(StatusFile.load(from: url))
    }

    func testGarbageAndAMissingFileAreBothNil() throws {
        let url = directory.appendingPathComponent("status.json")
        XCTAssertNil(StatusFile.load(from: url))

        try Data("{ not json at all".utf8).write(to: url)
        XCTAssertNil(StatusFile.load(from: url))
    }

    func testFreshnessIsTenMinutes() {
        let snapshot = sample()
        XCTAssertTrue(snapshot.isFresh(now: now.addingTimeInterval(599)))
        XCTAssertFalse(snapshot.isFresh(now: now.addingTimeInterval(601)))
    }

    func testTheEnvironmentOverrideWinsAndTheDefaultIsUnderApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(
            StatusFile.defaultURL(home: home).path,
            "/Users/tester/Library/Application Support/UsageTracker/status.json"
        )
        XCTAssertEqual(
            StatusFile.url(environment: [StatusFile.environmentKey: "/tmp/x.json"], home: home).path,
            "/tmp/x.json"
        )
        XCTAssertEqual(
            StatusFile.url(environment: [StatusFile.environmentKey: ""], home: home).path,
            StatusFile.defaultURL(home: home).path,
            "an empty override is not an override"
        )
    }

    func testPromotionalWindowsAreRecognisedTheWayBucketsAre() {
        XCTAssertTrue(StatusSnapshot.Window(id: "seven_day_promotional", label: "Bonus", percent: 3).isPromotional)
        XCTAssertTrue(StatusSnapshot.Window(id: "x", label: "Promo pool", percent: 3).isPromotional)
        XCTAssertFalse(StatusSnapshot.Window(id: "five_hour", label: "Session", percent: 3).isPromotional)
    }
}
