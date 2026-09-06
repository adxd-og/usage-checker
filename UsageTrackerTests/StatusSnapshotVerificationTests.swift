import XCTest
@testable import Omelette

/// Independent verification of `StatusSnapshot` / `StatusFile`, derived from the
/// spec's freshness and versioning rules, not from `StatusSnapshotTests`. Focus: the
/// exact freshness boundary (the existing suite checks 599/601; this pins the boundary
/// value itself), an empty-services round trip, and a `version: 2` file (the spec's own
/// example of "future") rather than an arbitrary 99.
final class StatusSnapshotVerificationTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusSnapshotVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(services: [StatusSnapshot.Service] = []) -> StatusSnapshot {
        StatusSnapshot(version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none)
    }

    /// The freshness window is a half-open interval: `[0, 600)` seconds old counts as
    /// fresh. Exactly 600.0 seconds must already read as stale, not the last fresh
    /// instant — a `<` gate, not `<=`.
    func testFreshnessBoundaryIsHalfOpenAtExactlySixHundredSeconds() {
        let snap = snapshot()
        XCTAssertTrue(snap.isFresh(now: now.addingTimeInterval(599.999)))
        XCTAssertFalse(snap.isFresh(now: now.addingTimeInterval(600.0)), "exactly 600s old is already stale")
        XCTAssertFalse(snap.isFresh(now: now.addingTimeInterval(600.001)))
    }

    /// An empty `services` array round-trips through the same encoder/decoder as a
    /// populated one — nothing about the "no provider yet" state should decode
    /// differently or lose the agents block.
    func testAnEmptyServicesListRoundTrips() throws {
        let empty = StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now, services: [],
            agents: StatusSnapshot.Agents(needsYou: 2, working: 1, sessions: [])
        )
        let url = directory.appendingPathComponent("status.json")
        try StatusFile.encoder.encode(empty).write(to: url)

        let loaded = try XCTUnwrap(StatusFile.load(from: url))
        XCTAssertEqual(loaded, empty)
        XCTAssertTrue(loaded.services.isEmpty)
        XCTAssertEqual(loaded.agents.needsYou, 2)
    }

    /// The spec's own worked example of a rejected file is `version: 2` (this build's
    /// `currentVersion` is 1) — not an arbitrary large number. Pin that exact value.
    func testVersionTwoIsRejectedEvenThoughItIsOnlyOneAhead() throws {
        XCTAssertEqual(StatusSnapshot.currentVersion, 1, "this test's premise: 2 is the very next version")
        let url = directory.appendingPathComponent("status.json")
        var future = snapshot()
        future.version = 2
        try StatusFile.encoder.encode(future).write(to: url)

        XCTAssertNil(StatusFile.load(from: url), "one version ahead is still a file this build cannot trust")
    }

    /// `StatusFile.read` (used by `--json`) must return the raw bytes even for a file
    /// whose version this build does not know — `--json` prints the file verbatim, and
    /// a version check belongs to `status`'s human-readable path, not to the raw dump.
    func testReadReturnsRawBytesEvenForAnUnknownVersion() throws {
        let url = directory.appendingPathComponent("status.json")
        var future = snapshot()
        future.version = 2
        let data = try StatusFile.encoder.encode(future)
        try data.write(to: url)

        XCTAssertEqual(StatusFile.read(from: url), data)
    }
}
