import XCTest
@testable import Omelette

/// Independent verification of the liquid-glass redesign spec, P8 row ("Remove the
/// Gemini CLI provider", line 238) and § Removals' Gemini line (line 220), plus the
/// owner's binding clarification of 2026-09-26: the `gemini` service id must never be
/// among the providers a launch polls or seeds, for any combination of the other
/// switches, and the dashboard's picker must never offer a `gemini` id or heal onto one.
///
/// This file exercises `AppState.polledServiceIDs`, `AppState.seededSnapshot` and
/// `DashboardState.availableServices` / `healedSelection` from fresh fixtures, not from
/// the executor's own `RemovedProviderRecordsTests`.
final class GeminiRemovalSeedingVerificationTests: XCTestCase {
    // MARK: - polledServiceIDs: every combination of the other three switches

    /// The rule takes four booleans; brute-forcing all sixteen combinations is the only
    /// way to honour the spec's "never polled" as an unconditional fact rather than a
    /// couple of hand-picked cases.
    func testPolledServiceIDsNeverContainsGeminiForAnyCombinationOfFlags() {
        for codex in [false, true] {
            for antigravity in [false, true] {
                for grok in [false, true] {
                    for adminKey in [false, true] {
                        let ids = AppState.polledServiceIDs(
                            codexEnabled: codex,
                            antigravityEnabled: antigravity,
                            grokEnabled: grok,
                            hasAdminKey: adminKey
                        )
                        XCTAssertFalse(
                            ids.contains("gemini"),
                            "codex=\(codex) antigravity=\(antigravity) grok=\(grok) adminKey=\(adminKey) polled \(ids)"
                        )
                        XCTAssertTrue(ids.contains("claude"), "Claude is never behind a switch")
                    }
                }
            }
        }
    }

    // MARK: - seededSnapshot: a stored gemini entry next to claude

    /// The stored dictionary carries a gemini entry ordered *before* claude
    /// (`order: 0` vs `order: 5`) so that, if the id filter were ever dropped in favour
    /// of only a sort, gemini would sort first and the test would catch it landing on
    /// the seeded snapshot at all, in any position.
    func testSeededSnapshotWithAStoredGeminiEntryAheadOfClaudeSeedsClaudeOnly() {
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let geminiSnapshot = Fixture.snapshot(
            id: "gemini", displayName: "Gemini", icon: "diamond", plan: "Gemini Pro",
            buckets: [Fixture.bucket(id: "gemini_pro", label: "Pro (daily)", percent: 88, kind: .modelSpecific)],
            at: readAt
        )
        let claudeSnapshot = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 12, kind: .session)],
            at: readAt
        )
        let stored: [String: LastKnownService] = [
            "gemini": LastKnownService(from: geminiSnapshot, order: 0),
            "claude": LastKnownService(from: claudeSnapshot, order: 5),
        ]

        let polled = AppState.polledServiceIDs(
            codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: false
        )
        let seeded = AppState.seededSnapshot(from: stored, enabledServiceIDs: polled)

        XCTAssertEqual(seeded.services.map(\.id), ["claude"], "gemini must not be seeded even when it would sort first")
        XCTAssertEqual(seeded.services.first?.buckets.first?.utilization, 12)
    }

    /// With every switch on (so `polled` is at its widest) a stored gemini entry is
    /// still excluded — the filter is by identity, not by which switches happen to be off.
    func testSeededSnapshotExcludesGeminiEvenWhenEveryOtherSwitchIsOn() {
        let readAt = Date(timeIntervalSince1970: 1_800_100_000)
        let stored: [String: LastKnownService] = [
            "gemini": LastKnownService(
                from: Fixture.snapshot(id: "gemini", displayName: "Gemini", at: readAt), order: 1
            ),
            "claude": LastKnownService(
                from: Fixture.snapshot(id: "claude", displayName: "Claude", at: readAt), order: 0
            ),
            "codex": LastKnownService(
                from: Fixture.snapshot(id: "codex", displayName: "Codex", at: readAt), order: 2
            ),
        ]
        let polled = AppState.polledServiceIDs(
            codexEnabled: true, antigravityEnabled: true, grokEnabled: true, hasAdminKey: true
        )
        let seeded = AppState.seededSnapshot(from: stored, enabledServiceIDs: polled)
        XCTAssertEqual(Set(seeded.services.map(\.id)), ["claude", "codex"])
    }

    // MARK: - DashboardState.availableServices

    func testAvailableServicesWithGeminiAndClaudeRecordedAndNoLiveServicesOffersClaudeOnly() {
        let offered = DashboardState.availableServices(
            recorded: ["gemini", "claude"],
            snapshot: UsageSnapshot(services: [], fetchedAt: Date(), isStale: false, lastError: nil),
            disabled: []
        )
        XCTAssertEqual(offered, ["claude"])
    }

    func testAvailableServicesWithOnlyGeminiRecordedOffersNothing() {
        let offered = DashboardState.availableServices(
            recorded: ["gemini"],
            snapshot: UsageSnapshot(services: [], fetchedAt: Date(), isStale: false, lastError: nil),
            disabled: []
        )
        XCTAssertEqual(offered, [], "the only recorded provider is one this build no longer polls")
    }

    // Session ruling (2026-09-26): a live entry is offered as the coordinator returned
    // it. The spec's P8 row speaks of stored records only; the live half of
    // `availableServices` is the coordinator's answer, and the coordinator no longer
    // fetches gemini, so no test pins a live gemini reading.

    // MARK: - DashboardState.healedSelection (default `polled` parameter, i.e. real usage)

    func testHealedSelectionStoredGeminiWithNothingOnOfferGoesToClaude() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "gemini", available: []), "claude")
    }

    func testHealedSelectionStoredCodexWithNothingOnOfferStandsStill() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "codex", available: []), "codex")
    }

    func testHealedSelectionStoredGeminiWithGrokOnOfferMovesToGrok() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "gemini", available: ["grok"]), "grok")
    }
}
