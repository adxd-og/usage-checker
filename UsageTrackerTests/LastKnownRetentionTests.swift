import XCTest
@testable import Omelette

/// Two rules decide whether last-known numbers reach the screen: what the app
/// renders before its first poll returns, and what it does with a provider that
/// comes back empty. Both are pure statics on AppState.
final class LastKnownRetentionTests: XCTestCase {
    private let stored = Date(timeIntervalSince1970: 1_788_000_000)

    private func entry(
        id: String,
        percent: Double,
        order: Int,
        at date: Date? = nil,
        plan: String? = "Antigravity Pro",
        cost: Double? = 3.5
    ) -> LastKnownService {
        LastKnownService(
            from: Fixture.snapshot(
                id: id,
                displayName: id.capitalized,
                plan: plan,
                buckets: [Fixture.bucket(id: "\(id)_window", percent: percent)],
                weekCost: cost,
                at: date ?? stored
            ),
            order: order
        )
    }

    private func snapshot(_ services: [ServiceSnapshot], at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date ?? stored, isStale: false, lastError: nil)
    }

    // MARK: - seededSnapshot

    func testTheSeededSnapshotCarriesTheStoredNumbersQuietly() throws {
        let seeded = AppState.seededSnapshot(from: ["antigravity": entry(id: "antigravity", percent: 62, order: 0)])

        let service = try XCTUnwrap(seeded.services.first)
        XCTAssertEqual(service.id, "antigravity")
        XCTAssertEqual(service.displayName, "Antigravity")
        XCTAssertEqual(service.plan, "Antigravity Pro")
        XCTAssertEqual(service.buckets.first?.utilization, 62)
        XCTAssertEqual(service.weekCost, 3.5)
        XCTAssertEqual(service.state, .notRunning, "nothing has been polled yet — the quiet state, not an error")
        XCTAssertNil(service.stateMessage, "there is no failure to explain on launch")
        XCTAssertEqual(service.fetchedAt, stored)
        XCTAssertTrue(service.isRetained)
    }

    func testTheSeededSnapshotIsStaleAndDatedFromTheStoredReading() {
        let seeded = AppState.seededSnapshot(from: [
            "claude": entry(id: "claude", percent: 20, order: 0, at: stored),
            "antigravity": entry(id: "antigravity", percent: 62, order: 1, at: stored.addingTimeInterval(300)),
        ])

        XCTAssertTrue(seeded.isStale)
        XCTAssertEqual(seeded.fetchedAt, stored.addingTimeInterval(300),
                       "the header must not claim to have just updated")
        XCTAssertNil(seeded.lastError)
    }

    func testSeededServicesKeepThePollOrder() {
        let seeded = AppState.seededSnapshot(from: [
            "antigravity": entry(id: "antigravity", percent: 62, order: 2),
            "claude": entry(id: "claude", percent: 20, order: 0),
            "codex": entry(id: "codex", percent: 40, order: 1),
        ])

        XCTAssertEqual(seeded.services.map(\.id), ["claude", "codex", "antigravity"],
                       "tiles that reshuffle when the first poll lands read as a bug")
    }

    func testNothingStoredMeansTheEmptySnapshot() {
        XCTAssertEqual(AppState.seededSnapshot(from: [:]), .empty)
    }

    // MARK: - seededSnapshot honours the provider toggles

    func testAProviderTheUserTurnedOffIsNotSeeded() {
        // The file remembers every provider that ever reported. Seeding all of them
        // would flash a switched-off provider onto the All tab for one poll cycle.
        let seeded = AppState.seededSnapshot(
            from: [
                "claude": entry(id: "claude", percent: 20, order: 0),
                "grok": entry(id: "grok", percent: 44, order: 1),
                "antigravity": entry(id: "antigravity", percent: 62, order: 2),
            ],
            enabledServiceIDs: ["claude", "antigravity"]
        )

        XCTAssertEqual(seeded.services.map(\.id), ["claude", "antigravity"],
                       "a disabled provider must not appear before the first poll")
    }

    func testClaudeIsSeededBecauseItIsAlwaysPolled() throws {
        let seeded = AppState.seededSnapshot(
            from: ["claude": entry(id: "claude", percent: 20, order: 0)],
            enabledServiceIDs: ["claude"]
        )

        let service = try XCTUnwrap(seeded.services.first)
        XCTAssertEqual(service.id, "claude")
        XCTAssertEqual(service.buckets.first?.utilization, 20)
    }

    func testEverythingBeingDisabledSeedsNothingAtAll() {
        let seeded = AppState.seededSnapshot(
            from: ["grok": entry(id: "grok", percent: 44, order: 0)],
            enabledServiceIDs: ["claude"]
        )

        XCTAssertEqual(seeded, .empty, "no enabled provider has stored numbers: nothing to seed")
    }

    // MARK: - retainingLastGoodServices

    func testThisSessionsOwnPollWinsOverTheFile() throws {
        let previous = snapshot([Fixture.snapshot(
            id: "antigravity",
            buckets: [Fixture.bucket(id: "antigravity_window", percent: 71)],
            at: stored.addingTimeInterval(600)
        )])
        let next = snapshot([Fixture.snapshot(id: "antigravity", plan: nil, buckets: [], state: .notRunning,
                                              stateMessage: "Antigravity isn't running")])

        let merged = AppState.retainingLastGoodServices(
            previous: previous,
            next: next,
            stored: ["antigravity": entry(id: "antigravity", percent: 62, order: 0)]
        )

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(service.buckets.first?.utilization, 71, "the file is only for a provider this session never saw")
        XCTAssertEqual(service.fetchedAt, stored.addingTimeInterval(600))
        XCTAssertEqual(service.state, .notRunning)
        XCTAssertEqual(service.stateMessage, "Antigravity isn't running")
    }

    func testTheFileSpeaksForAProviderThatNeverReportedThisSession() throws {
        // The relaunch case: nothing in memory, Antigravity closed, first poll empty.
        let next = snapshot([Fixture.snapshot(id: "antigravity", plan: nil, buckets: [], state: .notRunning,
                                              stateMessage: "Antigravity isn't running")])

        let merged = AppState.retainingLastGoodServices(
            previous: .empty,
            next: next,
            stored: ["antigravity": entry(id: "antigravity", percent: 62, order: 0)]
        )

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(service.buckets.first?.utilization, 62)
        XCTAssertEqual(service.plan, "Antigravity Pro")
        XCTAssertEqual(service.weekCost, 3.5)
        XCTAssertEqual(service.fetchedAt, stored)
        XCTAssertTrue(service.isRetained)
    }

    func testAServiceThatReportedIsLeftAlone() throws {
        let next = snapshot([Fixture.snapshot(
            id: "antigravity",
            buckets: [Fixture.bucket(id: "antigravity_window", percent: 5)]
        )])

        let merged = AppState.retainingLastGoodServices(
            previous: .empty,
            next: next,
            stored: ["antigravity": entry(id: "antigravity", percent: 62, order: 0)]
        )

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(service.buckets.first?.utilization, 5, "fresh numbers are never overwritten by old ones")
        XCTAssertFalse(service.isRetained)
    }

    func testAFailureWithNoStoredReadingStaysBare() throws {
        let next = snapshot([Fixture.snapshot(id: "codex", plan: nil, buckets: [], state: .notSignedIn,
                                              stateMessage: "Sign in")])

        let merged = AppState.retainingLastGoodServices(previous: .empty, next: next, stored: [:])

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertTrue(service.buckets.isEmpty)
        XCTAssertFalse(service.isRetained)
        XCTAssertEqual(service.stateMessage, "Sign in")
    }

    func testTheSnapshotEnvelopeComesFromTheFreshPoll() {
        let next = UsageSnapshot(services: [], fetchedAt: stored, isStale: false, lastError: "boom")

        let merged = AppState.retainingLastGoodServices(previous: .empty, next: next, stored: [:])

        XCTAssertEqual(merged.fetchedAt, stored)
        XCTAssertFalse(merged.isStale)
        XCTAssertEqual(merged.lastError, "boom")
    }
}
