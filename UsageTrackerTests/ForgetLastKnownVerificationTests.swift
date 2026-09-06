import XCTest
@testable import Omelette

/// Independent verification of "Forget last known numbers" (spec: `LastKnownStore.
/// forget(serviceID:)` and `AppState.droppingRetained(serviceID:from:)`), covering
/// cases the executor's `ForgetLastKnownTests` does not: forgetting an id that was
/// never stored must leave the file's bytes alone (not just its parsed keys), and
/// `droppingRetained` must leave a service that is merely *not currently retained*
/// untouched even though it shares the target id in spirit.
final class ForgetLastKnownVerificationTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let stored = Date(timeIntervalSince1970: 1_788_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgetLastKnownVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> LastKnownStore { LastKnownStore(fileURL: fileURL) }

    private func reading(_ id: String, percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(
            id: id, displayName: id.capitalized,
            buckets: [Fixture.bucket(id: "\(id)_window", label: "Window", percent: percent)],
            weekCost: 3.5, at: stored
        )
    }

    // MARK: - LastKnownStore.forget on an id that was never stored

    func testForgettingAnIDThatWasNeverStoredLeavesTheFileByteForByteUnchanged() async throws {
        let s = store()
        await s.remember([reading("grok", percent: 20), reading("codex", percent: 55)])
        let before = try Data(contentsOf: fileURL)

        await s.forget(serviceID: "antigravity")

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "a no-op forget must not rewrite the file at all")
    }

    func testForgettingTwiceIsIdempotent() async throws {
        let s = store()
        await s.remember([reading("antigravity", percent: 62)])
        await s.forget(serviceID: "antigravity")
        await s.forget(serviceID: "antigravity")

        let reloaded = await store().load()
        XCTAssertTrue(reloaded.isEmpty)
    }

    func testForgettingOneOfThreeLeavesTheOtherTwoWithTheirExactValues() async throws {
        let s = store()
        await s.remember([
            reading("antigravity", percent: 62),
            reading("grok", percent: 20),
            reading("codex", percent: 41),
        ])

        await s.forget(serviceID: "grok")

        let reloaded = await store().load()
        XCTAssertEqual(Set(reloaded.keys), ["antigravity", "codex"])
        XCTAssertEqual(reloaded["antigravity"]?.buckets.first?.utilization, 62)
        XCTAssertEqual(reloaded["codex"]?.buckets.first?.utilization, 41)
    }

    // MARK: - AppState.droppingRetained: a service that is not (or no longer) retained

    func testAServiceWithTheTargetIDButAlreadyNoBucketsIsUntouched() {
        // isRetained requires !buckets.isEmpty; a service that already has nothing to
        // drop must come back byte-for-byte identical, not merely "still empty".
        let alreadyCleared = Fixture.snapshot(
            id: "antigravity", buckets: [], state: .notRunning, stateMessage: "Antigravity isn't running", at: stored
        )
        let snapshot = UsageSnapshot(services: [alreadyCleared], fetchedAt: stored, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: snapshot)

        XCTAssertEqual(after, snapshot)
    }

    func testAServiceThatIsOKWithTheTargetIDIsNeverTreatedAsRetained() {
        // state == .ok makes isRetained false regardless of how full the buckets are —
        // droppingRetained must not clear a service just because its id matches while
        // it happens to be live right now.
        let live = Fixture.snapshot(
            id: "antigravity", buckets: [Fixture.bucket(id: "gemini_pro", percent: 30)],
            weekCost: 4, state: .ok, at: stored
        )
        let snapshot = UsageSnapshot(services: [live], fetchedAt: stored, isStale: false, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: snapshot)

        XCTAssertEqual(after, snapshot)
        XCTAssertFalse(after.services[0].buckets.isEmpty)
    }

    func testDroppingRetainedPreservesServiceOrderAndCount() {
        let retained = Fixture.snapshot(id: "antigravity", buckets: [Fixture.bucket(id: "a", percent: 62)], state: .notRunning, at: stored)
        let middle = Fixture.snapshot(id: "grok", buckets: [Fixture.bucket(id: "g", percent: 30)], state: .error, at: stored)
        let last = Fixture.snapshot(id: "codex", buckets: [Fixture.bucket(id: "c", percent: 11)], state: .ok, at: stored)
        let snapshot = UsageSnapshot(services: [retained, middle, last], fetchedAt: stored, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: snapshot)

        XCTAssertEqual(after.services.map(\.id), ["antigravity", "grok", "codex"], "no reordering, no drops")
        XCTAssertTrue(after.services[0].buckets.isEmpty)
        XCTAssertEqual(after.services[1].buckets.map(\.id), ["g"])
        XCTAssertEqual(after.services[2].buckets.map(\.id), ["c"])
    }

    func testDroppingRetainedAlsoClearsAccountLabelAndPlanNotJustBuckets() {
        let retained = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", plan: "Antigravity Pro", accountLabel: "me@example.com",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            weekCost: 3.5, state: .notRunning, stateMessage: "Antigravity isn't running", at: stored
        )
        let snapshot = UsageSnapshot(services: [retained], fetchedAt: stored, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: snapshot).services[0]

        XCTAssertNil(after.plan)
        XCTAssertNil(after.accountLabel)
        XCTAssertNil(after.weekCost)
        // The identity fields the row still needs to draw the tile survive.
        XCTAssertEqual(after.displayName, "Antigravity")
        XCTAssertEqual(after.id, "antigravity")
    }
}
