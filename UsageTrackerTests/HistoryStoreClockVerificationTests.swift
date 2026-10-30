import XCTest
@testable import Omelette

/// Verification of the injected clock behind `HistoryStore`'s 90-day prune (owner 2026-10-30,
/// side fix): the cutoff is `now() - 90 days`, a record exactly on it stays, one second older goes,
/// and a store built without a clock measures against the real one.
final class HistoryStoreClockVerificationTests: XCTestCase {
    private var directory: URL!
    private let ninetyDays: TimeInterval = 90 * 24 * 3600
    private let pinned = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreClockVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var log: URL { directory.appendingPathComponent("history.jsonl") }

    private func writeLog(_ records: [(service: String, at: Date)]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for (service, date) in records {
            data.append(try encoder.encode(HistoryRecord(from: Fixture.snapshot(id: service), at: date)))
            data.append(0x0A)
        }
        try data.write(to: log)
    }

    func testARecordOnTheCutoffStaysAndOneSecondOlderIsPruned() async throws {
        let cutoff = pinned.addingTimeInterval(-ninetyDays)
        try writeLog([
            ("older", cutoff.addingTimeInterval(-1)),
            ("onCutoff", cutoff),
            ("newer", cutoff.addingTimeInterval(1)),
        ])

        let store = HistoryStore(directory: directory, now: { [pinned] in pinned })
        let services = await store.recordedServices()

        XCTAssertEqual(services, ["newer", "onCutoff"])
    }

    func testThePrunedRecordIsGoneFromTheLogOnDiskToo() async throws {
        let cutoff = pinned.addingTimeInterval(-ninetyDays)
        try writeLog([("older", cutoff.addingTimeInterval(-60)), ("kept", cutoff.addingTimeInterval(60))])

        _ = await HistoryStore(directory: directory, now: { [pinned] in pinned }).recordedServices()

        // A store whose clock is a year earlier would keep both; only the rewritten file decides.
        let early = pinned.addingTimeInterval(-365 * 24 * 3600)
        let reread = await HistoryStore(directory: directory, now: { early }).recordedServices()
        XCTAssertEqual(reread, ["kept"])
    }

    func testTheCutoffFollowsTheClockItIsGiven() async throws {
        try writeLog([("a", pinned)])

        let justInside = pinned.addingTimeInterval(ninetyDays - 1)
        let justOutside = pinned.addingTimeInterval(ninetyDays + 1)
        let soon = await HistoryStore(directory: directory, now: { justInside }).recordedServices()
        XCTAssertEqual(soon, ["a"], "89 days 23 h 59 min 59 s old")

        try writeLog([("a", pinned)])
        let late = await HistoryStore(directory: directory, now: { justOutside }).recordedServices()
        XCTAssertEqual(late, [], "90 days and a second old")
    }

    func testWithoutAClockTheRealOneIsUsed() async throws {
        let realNow = Date()
        try writeLog([
            ("yesterday", realNow.addingTimeInterval(-24 * 3600)),
            ("eightyNineDays", realNow.addingTimeInterval(-89 * 24 * 3600)),
            ("ninetyOneDays", realNow.addingTimeInterval(-91 * 24 * 3600)),
        ])

        let services = await HistoryStore(directory: directory).recordedServices()

        XCTAssertEqual(services, ["eightyNineDays", "yesterday"])
    }
}
