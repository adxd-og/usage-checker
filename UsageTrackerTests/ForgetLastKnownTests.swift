import XCTest
@testable import Omelette

/// "Forget last known numbers": the stored reading goes, and the dimmed numbers on
/// screen go with it in the same turn. A button whose effect only shows up after the
/// next poll reads as broken.
final class ForgetLastKnownTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let stored = Date(timeIntervalSince1970: 1_788_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgetLastKnownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> LastKnownStore { LastKnownStore(fileURL: fileURL) }

    private func reading(_ id: String, percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(
            id: id,
            displayName: id.capitalized,
            buckets: [Fixture.bucket(id: "\(id)_window", label: "Window", percent: percent)],
            weekCost: 3.5,
            at: stored
        )
    }

    // MARK: - The store

    func testForgettingRemovesOnlyThatServiceAndSurvivesARelaunch() async throws {
        let s = store()
        await s.remember([reading("antigravity", percent: 62), reading("grok", percent: 20)])

        await s.forget(serviceID: "antigravity")

        let reloaded = await store().load()
        XCTAssertNil(reloaded["antigravity"], "the file is the thing the user asked to clear")
        XCTAssertNotNil(reloaded["grok"])
    }

    func testForgettingAServiceThatIsNotStoredWritesNothing() async throws {
        let s = store()
        await s.remember([reading("grok", percent: 20)])
        await s.forget(serviceID: "antigravity")

        let reloaded = await store().load()
        XCTAssertEqual(Set(reloaded.keys), ["grok"])
    }

    func testAForgottenServiceCanBeRememberedAgain() async throws {
        let s = store()
        await s.remember([reading("antigravity", percent: 62)])
        await s.forget(serviceID: "antigravity")
        await s.remember([reading("antigravity", percent: 71)])

        let reloaded = await store().load()
        XCTAssertEqual(reloaded["antigravity"]?.buckets.first?.utilization, 71)
    }

    // MARK: - The snapshot rule

    func testTheRetainedNumbersLeaveTheSnapshotImmediately() {
        let retained = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", plan: "Antigravity Pro",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25),
            weekCost: 3.5, state: .notRunning, stateMessage: "Antigravity isn't running", at: stored
        )
        let snapshot = UsageSnapshot(services: [retained], fetchedAt: stored, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: snapshot)

        let service = after.services[0]
        XCTAssertTrue(service.buckets.isEmpty)
        XCTAssertNil(service.plan)
        XCTAssertNil(service.accountLabel)
        XCTAssertNil(service.extraUsage)
        XCTAssertNil(service.weekCost)
        XCTAssertFalse(service.isRetained, "with no buckets there is nothing left to call retained")
        XCTAssertEqual(service.state, .notRunning, "the state chip still says why it stopped")
        XCTAssertEqual(service.stateMessage, "Antigravity isn't running")
    }

    func testALiveServiceIsNeverTouched() {
        let live = Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 42, kind: .session)],
            weekCost: 9, state: .ok, at: stored
        )
        let snapshot = UsageSnapshot(services: [live], fetchedAt: stored, isStale: false, lastError: nil)
        XCTAssertEqual(AppState.droppingRetained(serviceID: "claude", from: snapshot), snapshot)
    }

    func testTheOtherServicesAreNeverTouched() {
        let retained = Fixture.snapshot(
            id: "antigravity", buckets: [Fixture.bucket(id: "a", percent: 62)], state: .notRunning, at: stored
        )
        let other = Fixture.snapshot(
            id: "grok", buckets: [Fixture.bucket(id: "g", percent: 30)], state: .error, at: stored
        )
        let snapshot = UsageSnapshot(services: [retained, other], fetchedAt: stored, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: snapshot)

        XCTAssertTrue(after.services[0].buckets.isEmpty)
        XCTAssertEqual(after.services[1].buckets.map(\.id), ["g"])
        XCTAssertEqual(after.fetchedAt, stored)
        XCTAssertTrue(after.isStale)
    }
}
