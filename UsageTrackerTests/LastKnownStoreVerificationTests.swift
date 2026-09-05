import XCTest
@testable import Omelette

/// Independent verification of `LastKnownStore`, written without reading the
/// executor's `LastKnownStoreTests.swift`. Attacks the store's persistence
/// contract from angles the plan's own tests didn't cover explicitly: an ok
/// poll with nothing in its buckets, a missing file, concurrent writers, and
/// the file's location relative to history.jsonl.
final class LastKnownStoreVerificationTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    private let stored = Date(timeIntervalSince1970: 1_788_100_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastKnownStoreVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> LastKnownStore { LastKnownStore(fileURL: fileURL) }

    private func ok(id: String, percent: Double, at date: Date, plan: String? = "Pro",
                     displayName: String = "Codex", icon: String = "terminal") -> ServiceSnapshot {
        // Built directly rather than through Fixture.snapshot: that fixture hardcodes
        // icon to "sparkles", which would silently defeat the icon round-trip below.
        ServiceSnapshot(
            id: id,
            displayName: displayName,
            icon: icon,
            plan: plan,
            accountLabel: nil,
            buckets: [Fixture.bucket(id: "\(id)_window", label: "Window", percent: percent)],
            extraUsage: nil,
            weekCost: nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: date
        )
    }

    // MARK: - Round trip of every field

    func testEveryFieldRoundTripsIncludingOrderDisplayNameAndIcon() async throws {
        await store().remember([
            ok(id: "codex", percent: 40, at: stored, displayName: "Codex", icon: "terminal"),
            ok(id: "claude", percent: 20, at: stored, displayName: "Claude", icon: "sparkles"),
        ])

        let reloaded = await store().load()
        let codex = try XCTUnwrap(reloaded["codex"])
        let claude = try XCTUnwrap(reloaded["claude"])

        XCTAssertEqual(codex.displayName, "Codex")
        XCTAssertEqual(codex.icon, "terminal")
        XCTAssertEqual(codex.order, 0)
        XCTAssertEqual(claude.displayName, "Claude")
        XCTAssertEqual(claude.icon, "sparkles")
        XCTAssertEqual(claude.order, 1)
    }

    // MARK: - ok + empty buckets: not remembered, and does not erase an older good entry

    func testAnOkPollWithEmptyBucketsDoesNotEraseAPreviousGoodEntry() async throws {
        let s = store()
        await s.remember([ok(id: "antigravity", percent: 62, at: stored)])

        // A later poll reports .ok (no error!) but with no buckets — e.g. the API
        // replied 200 with an empty payload. This must not be treated as "nothing
        // to remember and nothing to preserve" in a way that wipes the old entry.
        await s.remember([
            Fixture.snapshot(id: "antigravity", plan: nil, buckets: [], state: .ok, at: stored.addingTimeInterval(600)),
        ])

        let reloaded = await s.load()
        let entry = try XCTUnwrap(reloaded["antigravity"])
        XCTAssertEqual(entry.buckets.first?.utilization, 62, "an ok-but-empty poll must not erase the last good reading")
        XCTAssertEqual(entry.fetchedAt, stored)
    }

    // MARK: - Missing file loads as empty

    func testAMissingFileLoadsAsEmptyRatherThanThrowing() async {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = await store().load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testAFreshActorAfterAMissingFileLoadCanStillWrite() async throws {
        _ = await store().load()
        let s = store()
        await s.remember([ok(id: "claude", percent: 10, at: stored)])
        let reloaded = await s.load()
        XCTAssertEqual(reloaded["claude"]?.buckets.first?.utilization, 10)
    }

    // MARK: - Concurrent remember calls end consistent

    func testConcurrentRememberCallsForDifferentServicesAreAllPersisted() async throws {
        let s = store()
        let snapshots: [ServiceSnapshot] = (0..<8).map { i in
            ok(id: "svc\(i)", percent: Double(i) * 5, at: stored, displayName: "Svc\(i)")
        }
        await withTaskGroup(of: Void.self) { group in
            for snap in snapshots {
                group.addTask {
                    await s.remember([snap])
                }
            }
        }

        let reloaded = await s.load()
        for i in 0..<8 {
            let entry = try? XCTUnwrap(reloaded["svc\(i)"])
            XCTAssertEqual(entry?.buckets.first?.utilization, Double(i) * 5, "svc\(i) lost a concurrent write")
        }
        XCTAssertEqual(reloaded.count, 8, "concurrent remember calls on the actor must not drop entries")
    }

    func testConcurrentRememberCallsOnDiskSurviveAFreshLoad() async throws {
        // Re-verify through a brand new actor instance (forces a real file read),
        // the way a relaunch would.
        let s = store()
        let snapshots: [ServiceSnapshot] = (0..<5).map { i in
            ok(id: "svc\(i)", percent: Double(i), at: stored)
        }
        await withTaskGroup(of: Void.self) { group in
            for snap in snapshots {
                group.addTask {
                    await s.remember([snap])
                }
            }
        }
        let reloaded = await store().load()
        XCTAssertEqual(reloaded.count, 5)
    }

    // MARK: - File location

    func testTheDefaultFileLivesBesideHistoryJsonl() {
        XCTAssertEqual(LastKnownStore.defaultFileURL.lastPathComponent, "last-known.json")
        XCTAssertEqual(LastKnownStore.defaultFileURL.deletingLastPathComponent().standardizedFileURL,
                       HistoryStore.defaultDirectory.standardizedFileURL,
                       "last-known.json should sit in the same Application Support directory as history.jsonl")
    }
}
