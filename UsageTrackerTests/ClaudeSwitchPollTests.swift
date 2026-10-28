import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, "Off means off": a
/// Claude switched off is not polled, not seeded from `last-known.json` and gone from the
/// screen after the next poll, the way Codex off has always worked. The admin-key
/// organisation is independent of the switch: with Claude off it stands alone, and it
/// counts as something on.
final class ClaudeSwitchPollTests: XCTestCase {
    private let readAt = Date(timeIntervalSince1970: 1_793_100_000)

    private func claude() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 12, kind: .session)],
            at: readAt
        )
    }

    private func codex() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(id: "codex_session", label: "Session", percent: 30, kind: .session)],
            at: readAt
        )
    }

    private func admin(_ state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "anthropic-admin", displayName: "Anthropic Enterprise", icon: "building.2",
            plan: "Enterprise", weekCost: 120, state: state, at: readAt
        )
    }

    private func antigravity() -> ServiceSnapshot {
        Fixture.snapshot(id: "antigravity", displayName: "Antigravity", at: readAt)
    }

    private func grok() -> ServiceSnapshot {
        Fixture.snapshot(id: "grok", displayName: "Grok", at: readAt)
    }

    // MARK: - What a launch polls

    func testClaudeSwitchedOffIsNotPolled() {
        XCTAssertEqual(
            AppState.polledServiceIDs(
                claudeEnabled: false, codexEnabled: true, antigravityEnabled: false, grokEnabled: false, hasAdminKey: false
            ),
            ["codex"]
        )
    }

    func testClaudeSwitchedOnIsPolled() {
        XCTAssertEqual(
            AppState.polledServiceIDs(
                claudeEnabled: true, codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: false
            ),
            ["claude"]
        )
    }

    func testEverySwitchOffAndNoAdminKeyPollsNothing() {
        XCTAssertEqual(
            AppState.polledServiceIDs(
                claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: false
            ),
            []
        )
    }

    func testAnAdminKeyIsSomethingOnWithClaudeOff() {
        XCTAssertEqual(
            AppState.polledServiceIDs(
                claudeEnabled: false, codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: true
            ),
            ["anthropic-admin"]
        )
    }

    // MARK: - Seeding at launch

    func testAKeptClaudeReadingIsNotSeededWhileClaudeIsOff() {
        let stored: [String: LastKnownService] = [
            "claude": LastKnownService(from: claude(), order: 0),
            "codex": LastKnownService(from: codex(), order: 1),
        ]
        let polled = AppState.polledServiceIDs(
            claudeEnabled: false, codexEnabled: true, antigravityEnabled: false, grokEnabled: false, hasAdminKey: false
        )
        let seeded = AppState.seededSnapshot(from: stored, enabledServiceIDs: polled)
        XCTAssertEqual(seeded.services.map(\.id), ["codex"])
    }

    func testWithEverythingOffNothingIsSeeded() {
        let stored: [String: LastKnownService] = [
            "claude": LastKnownService(from: claude(), order: 0),
            "codex": LastKnownService(from: codex(), order: 1),
        ]
        let seeded = AppState.seededSnapshot(from: stored, enabledServiceIDs: [])
        XCTAssertTrue(seeded.services.isEmpty)
        XCTAssertFalse(seeded.hasAnyData)
    }

    // MARK: - The poll's order

    func testWithClaudeOffAPreferredAdminOrganisationStandsAlone() {
        let services = ProviderCoordinator.ordered(
            claude: nil, admin: admin(), codex: nil, antigravity: nil, grok: nil, preferAdmin: true
        )
        XCTAssertEqual(services.map(\.id), ["anthropic-admin"])
    }

    func testWithClaudeOffAnAdminOrganisationStandsAloneWhetherPreferredOrFailing() {
        XCTAssertEqual(
            ProviderCoordinator.ordered(
                claude: nil, admin: admin(), codex: nil, antigravity: nil, grok: nil, preferAdmin: false
            ).map(\.id),
            ["anthropic-admin"]
        )
        XCTAssertEqual(
            ProviderCoordinator.ordered(
                claude: nil, admin: admin(.error), codex: nil, antigravity: nil, grok: nil, preferAdmin: true
            ).map(\.id),
            ["anthropic-admin"]
        )
    }

    func testWithClaudeOffTheOthersKeepTheirOrder() {
        XCTAssertEqual(
            ProviderCoordinator.ordered(
                claude: nil, admin: admin(), codex: codex(), antigravity: antigravity(), grok: grok(), preferAdmin: true
            ).map(\.id),
            ["anthropic-admin", "codex", "antigravity", "grok"]
        )
    }

    func testWithClaudeOnTheOrderIsWhatItWas() {
        XCTAssertEqual(
            ProviderCoordinator.ordered(
                claude: claude(), admin: admin(), codex: codex(), antigravity: antigravity(), grok: grok(), preferAdmin: true
            ).map(\.id),
            ["anthropic-admin", "claude", "codex", "antigravity", "grok"],
            "a working admin organisation the user prefers goes first"
        )
        XCTAssertEqual(
            ProviderCoordinator.ordered(
                claude: claude(), admin: admin(.error), codex: nil, antigravity: nil, grok: nil, preferAdmin: true
            ).map(\.id),
            ["claude", "anthropic-admin"],
            "a failing one does not"
        )
        XCTAssertEqual(
            ProviderCoordinator.ordered(
                claude: claude(), admin: admin(), codex: nil, antigravity: nil, grok: nil, preferAdmin: false
            ).map(\.id),
            ["claude", "anthropic-admin"]
        )
    }

    func testNothingOnIsAnEmptyPoll() {
        XCTAssertTrue(ProviderCoordinator.ordered(
            claude: nil, admin: nil, codex: nil, antigravity: nil, grok: nil, preferAdmin: true
        ).isEmpty)
    }

    // MARK: - The screen after the poll

    func testThePollAfterClaudeIsSwitchedOffTakesItOffTheScreen() {
        let previous = UsageSnapshot(services: [claude(), codex()], fetchedAt: readAt, isStale: false, lastError: nil)
        let next = UsageSnapshot(
            services: [codex()], fetchedAt: readAt.addingTimeInterval(60), isStale: false, lastError: nil
        )
        let merged = AppState.mergingPoll(
            previous: previous, next: next, stored: ["claude": LastKnownService(from: claude(), order: 0)]
        )
        XCTAssertEqual(merged.services.map(\.id), ["codex"], "a kept Claude reading does not bring Claude back")
    }
}
