import XCTest
@testable import Omelette

/// The file behind "Antigravity showed numbers an hour ago" surviving a relaunch.
/// Every test points the store at its own temp file — the real one lives in
/// Application Support and a test run must never write there.
final class LastKnownStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    private let stored = Date(timeIntervalSince1970: 1_788_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastKnownStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fresh actor every time: the file is then the only channel between calls,
    /// which is exactly the relaunch this store exists for.
    private func store() -> LastKnownStore { LastKnownStore(fileURL: fileURL) }

    private func antigravity(percent: Double, at date: Date, cost: Double? = 3.5) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity",
            displayName: "Antigravity",
            plan: "Antigravity Pro",
            buckets: [Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: percent)],
            weekCost: cost,
            at: date
        )
    }

    func testAGoodReadingSurvivesARelaunch() async throws {
        await store().remember([antigravity(percent: 62, at: stored)])

        let reloaded = await store().load()

        let entry = try XCTUnwrap(reloaded["antigravity"])
        XCTAssertEqual(entry.displayName, "Antigravity")
        XCTAssertEqual(entry.icon, "sparkles")
        XCTAssertEqual(entry.plan, "Antigravity Pro")
        XCTAssertEqual(entry.buckets.map(\.id), ["antigravity_gemini"])
        XCTAssertEqual(entry.buckets.first?.utilization, 62)
        XCTAssertEqual(entry.weekCost, 3.5)
        XCTAssertEqual(entry.fetchedAt, stored)
        XCTAssertEqual(entry.order, 0)
    }

    func testOnlyAServiceThatActuallyReportedIsRemembered() async {
        let failing = Fixture.snapshot(
            id: "codex",
            buckets: [Fixture.bucket(id: "codex_session", percent: 40)],
            state: .notSignedIn,
            at: stored
        )
        let empty = Fixture.snapshot(id: "grok", buckets: [], state: .ok, at: stored)

        await store().remember([failing, empty])

        let reloaded = await store().load()
        XCTAssertTrue(reloaded.isEmpty, "a failed poll and an empty one are not readings worth keeping")
    }

    func testAFailingServiceKeepsWhatItStoredLast() async throws {
        let s = store()
        await s.remember([antigravity(percent: 62, at: stored)])
        await s.remember([
            Fixture.snapshot(id: "antigravity", buckets: [], state: .notRunning, at: stored.addingTimeInterval(600))
        ])

        let reloaded = await s.load()
        let entry = try XCTUnwrap(reloaded["antigravity"])
        XCTAssertEqual(entry.buckets.first?.utilization, 62, "the whole point of the file is this entry")
        XCTAssertEqual(entry.fetchedAt, stored)
    }

    func testUnchangedNumbersDoNotRestampTheEntry() async throws {
        // The poll runs every minute; rewriting the file each time to move a
        // timestamp by 60 s is disk traffic for nothing. Same numbers, same entry.
        let s = store()
        await s.remember([antigravity(percent: 62, at: stored)])
        await s.remember([antigravity(percent: 62, at: stored.addingTimeInterval(60))])

        var reloaded = await s.load()
        var entry = try XCTUnwrap(reloaded["antigravity"])
        XCTAssertEqual(entry.fetchedAt, stored)

        await s.remember([antigravity(percent: 63, at: stored.addingTimeInterval(120))])

        reloaded = await s.load()
        entry = try XCTUnwrap(reloaded["antigravity"])
        XCTAssertEqual(entry.fetchedAt, stored.addingTimeInterval(120))
        XCTAssertEqual(entry.buckets.first?.utilization, 63)
    }

    func testTheOrderOfThePollIsKept() async throws {
        await store().remember([
            Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 10)], at: stored),
            Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn, at: stored),
            antigravity(percent: 62, at: stored),
        ])

        let reloaded = await store().load()
        XCTAssertEqual(reloaded["claude"]?.order, 0)
        XCTAssertEqual(reloaded["antigravity"]?.order, 2)
    }

    func testAWriteThatFailedIsRetriedOnTheNextPoll() async throws {
        // The directory is missing, so the first write throws. Nothing else will
        // change for a while — Antigravity reports the same numbers every minute —
        // so unless the store remembers that it owes the disk a write, the file
        // never appears.
        let missing = directory.appendingPathComponent("not-yet", isDirectory: true)
        let target = missing.appendingPathComponent("last-known.json")
        let s = LastKnownStore(fileURL: target)

        await s.remember([antigravity(percent: 62, at: stored)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "the write had nowhere to go")

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        await s.remember([antigravity(percent: 62, at: stored.addingTimeInterval(60))])

        let reloaded = await LastKnownStore(fileURL: target).load()
        XCTAssertEqual(reloaded["antigravity"]?.buckets.first?.utilization, 62)
    }

    func testARenamedProviderIsWrittenEvenWithTheSameNumbers() async throws {
        let s = store()
        await s.remember([antigravity(percent: 62, at: stored)])

        let relabelled = Fixture.snapshot(
            id: "antigravity",
            displayName: "Antigravity Pro",
            icon: "bolt",
            plan: "Antigravity Pro",
            accountLabel: "work@example.com",
            buckets: [Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 62)],
            weekCost: 3.5,
            at: stored.addingTimeInterval(60)
        )
        await s.remember([relabelled])

        // A fresh actor reads the file rather than the cache: this is about what
        // survives a relaunch, and a seeded popover with the old name and the old
        // icon reads as a bug.
        let reloaded = await store().load()
        XCTAssertEqual(reloaded["antigravity"]?.displayName, "Antigravity Pro")
        XCTAssertEqual(reloaded["antigravity"]?.icon, "bolt")
        XCTAssertEqual(reloaded["antigravity"]?.accountLabel, "work@example.com")
    }

    func testAReorderedPollIsWrittenEvenWithTheSameNumbers() async throws {
        let s = store()
        let claude = Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 10)], at: stored)
        let anti = antigravity(percent: 62, at: stored)
        await s.remember([claude, anti])

        await s.remember([anti, claude])

        let reloaded = await store().load()
        XCTAssertEqual(reloaded["antigravity"]?.order, 0)
        XCTAssertEqual(reloaded["claude"]?.order, 1)
    }

    func testACorruptFileIsIgnoredRatherThanFatal() async throws {
        try Data("{ not json at all".utf8).write(to: fileURL)

        let afterCorrupt = await store().load()
        XCTAssertTrue(afterCorrupt.isEmpty)

        let s = store()
        await s.remember([antigravity(percent: 62, at: stored)])
        let reloaded = await s.load()
        XCTAssertEqual(reloaded["antigravity"]?.buckets.first?.utilization, 62)
    }
}
