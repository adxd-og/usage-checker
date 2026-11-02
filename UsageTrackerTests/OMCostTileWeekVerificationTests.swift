import XCTest
@testable import Omelette

/// Verification of the island cost tile's week: each service's week is the cost
/// gathering's figure when it has one, else the snapshot's own `weekCost`, and the same
/// figure decides the split, the caption, the VoiceOver text and whether the tile shows.
final class OMCostTileWeekVerificationTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func subscription(_ id: String, name: String, weekCost: Double? = nil, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(
            id: id, displayName: name,
            buckets: [Fixture.bucket(id: "\(id)_session", percent: 10, kind: .session)],
            weekCost: weekCost, state: state
        )
    }

    private func payg(_ id: String, name: String, weekCost: Double? = nil) -> ServiceSnapshot {
        Fixture.snapshot(id: id, displayName: name, buckets: [], weekCost: weekCost)
    }

    // MARK: - Zero entry versus absent entry

    /// A gathering that says "$0 this week" is an answer; it replaces a snapshot's figure.
    func testAGatheredZeroReplacesTheSnapshotsWeek() {
        let codex = subscription("codex", name: "Codex", weekCost: 5)
        XCTAssertEqual(OMCostTile.total([codex], week: ["codex": 0]), 0, accuracy: 0.0001)
        XCTAssertEqual(OMCostTile.breakdown([codex], week: ["codex": 0], locale: us), "")
        XCTAssertFalse(ProviderGridRules.showsCostTile([codex], week: ["codex": 0]))
    }

    func testAnAbsentEntryDoesNotReplaceTheSnapshotsWeek() {
        let codex = subscription("codex", name: "Codex", weekCost: 5)
        XCTAssertEqual(OMCostTile.total([codex], week: ["claude": 0]), 5, accuracy: 0.0001)
        XCTAssertTrue(ProviderGridRules.showsCostTile([codex], week: ["claude": 9]))
    }

    func testAGatheredZeroIsNotACaptionedContributor() {
        let codex = subscription("codex", name: "Codex", weekCost: 5)
        XCTAssertNil(OMCostTile.caption(services: [codex], today: [:], week: ["codex": 0]))
        XCTAssertEqual(
            OMCostTile.caption(services: [codex], today: ["codex": 1], week: ["codex": 0]),
            CostCopy.apiEquivalent,
            "today's dollars still count"
        )
    }

    // MARK: - Services on screen only

    /// The map carries every service the gathering read; a provider switched off is not
    /// in `displayedServices`, so its dollars are not in the tile.
    func testAServiceNotOnScreenIsNotCountedEvenWhenTheMapHasIt() {
        let claude = subscription("claude", name: "Claude")
        let week = ["claude": 10.0, "grok": 99.0, "codex": 50.0]
        XCTAssertEqual(OMCostTile.total([claude], week: week), 10, accuracy: 0.0001)
        XCTAssertEqual(OMCostTile.breakdown([claude], week: week, locale: us), "Claude $10.00")
        XCTAssertEqual(
            OMCostTile.secondary(services: [claude], today: ["claude": 1], week: week, locale: us),
            "Last 7 days $10.00 · Claude $10.00"
        )
    }

    func testTheTileStaysHiddenWhenOnlyAnOffScreenServiceHasDollars() {
        let claude = subscription("claude", name: "Claude")
        XCTAssertFalse(ProviderGridRules.showsCostTile([claude], week: ["grok": 99]))
    }

    // MARK: - Retained / not-running services

    /// A closed provider keeps its last-known numbers dimmed. Its local cost log is still
    /// on disk, so the gathered week replaces the retained snapshot's figure (the spec's
    /// "gathering when present").
    func testTheGatheredWeekReplacesARetainedSnapshotsWeek() {
        let retained = Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)],
            weekCost: 40, state: .notRunning
        )
        XCTAssertEqual(OMCostTile.total([retained], week: ["codex": 12]), 12, accuracy: 0.0001)
        XCTAssertEqual(OMCostTile.breakdown([retained], week: ["codex": 12], locale: us), "Codex $12.00")
    }

    /// Antigravity has no cost log: absent from the gathering, it keeps whatever the
    /// snapshot carries, and a retained entry without dollars adds none.
    func testARetainedServiceWithoutALogKeepsItsRetainedWeek() {
        let antigravity = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "agy", percent: 30, kind: .session)],
            weekCost: 7, state: .notRunning
        )
        let claude = subscription("claude", name: "Claude")
        XCTAssertEqual(
            OMCostTile.total([claude, antigravity], week: ["claude": 3]), 10, accuracy: 0.0001
        )
        let bare = Fixture.snapshot(id: "antigravity", displayName: "Antigravity", weekCost: nil, state: .notRunning)
        XCTAssertEqual(OMCostTile.total([claude, bare], week: ["claude": 3]), 3, accuracy: 0.0001)
    }

    // MARK: - Split and order

    func testTheSplitFollowsTheServicesOrderAndSkipsZeroWeeks() {
        let services = [
            subscription("grok", name: "Grok"),
            subscription("claude", name: "Claude"),
            subscription("codex", name: "Codex", weekCost: 4),
        ]
        let week = ["grok": 0.0, "claude": 2.5, "codex": 0.0]
        XCTAssertEqual(OMCostTile.breakdown(services, week: week, locale: us), "Claude $2.50")
    }

    func testThePayAsYouGoClaudeWeekFromTheGatheringMatchesItsSnapshot() {
        let claude = payg("claude", name: "Claude", weekCost: 25)
        XCTAssertEqual(OMCostTile.total([claude], week: ["claude": 25]), 25, accuracy: 0.0001)
        XCTAssertNil(OMCostTile.caption(services: [claude], today: [:], week: ["claude": 25]))
    }

    // MARK: - Captions

    /// Claude (subscription) is a contributor only through the gathered week; with it,
    /// a pay-as-you-go neighbour no longer makes the whole tile caption-free.
    func testAGatheredSubscriptionWeekMakesTheTileCaptioned() {
        let claude = subscription("claude", name: "Claude")
        let api = payg("grok", name: "Grok", weekCost: 3)
        XCTAssertNil(OMCostTile.caption(services: [claude, api], today: [:], week: [:]))
        XCTAssertEqual(
            OMCostTile.caption(services: [claude, api], today: [:], week: ["claude": 40]),
            CostCopy.apiEquivalent
        )
    }

    func testASubscriptionWithoutDollarsDoesNotCaptionAPaygNeighbour() {
        let claude = subscription("claude", name: "Claude")
        let api = payg("grok", name: "Grok", weekCost: 3)
        XCTAssertNil(OMCostTile.caption(services: [claude, api], today: [:], week: ["claude": 0]))
    }

    // MARK: - VoiceOver

    func testVoiceOverHeadlineIsTheGatheredWeekWhenTodayIsUnknown() {
        let claude = subscription("claude", name: "Claude")
        XCTAssertEqual(
            OMCostTile.accessibilityText(services: [claude], today: [:], week: ["claude": 1601.14], locale: us),
            "Last 7 days $1,601.14. \(CostCopy.apiEquivalent)"
        )
    }

    func testVoiceOverLeadsWithTodayAndCaptionsAWeekOnlyContributor() {
        let claude = subscription("claude", name: "Claude")
        XCTAssertEqual(
            OMCostTile.accessibilityText(services: [claude], today: ["claude": 0], week: ["claude": 40], locale: us),
            "Today $0.00. \(CostCopy.apiEquivalent)"
        )
    }

    func testVoiceOverWithoutAWeekMapIsAsBefore() {
        let claude = subscription("claude", name: "Claude", weekCost: 8)
        XCTAssertEqual(
            OMCostTile.accessibilityText(services: [claude], today: [:], locale: us),
            "Last 7 days $8.00. \(CostCopy.apiEquivalent)"
        )
    }

    // MARK: - The week and the headline are independent

    func testTheHeadlineStaysTodayWhileTheSecondaryLineCarriesTheGatheredWeek() {
        let claude = subscription("claude", name: "Claude")
        let todayTotal = OMCostTile.todayTotal([claude], today: ["claude": 5])
        XCTAssertEqual(todayTotal ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(
            OMCostTile.secondary(services: [claude], today: ["claude": 5], week: ["claude": 35], locale: us),
            "Last 7 days $35.00 · Claude $35.00"
        )
    }

    /// Without today's number the week is the headline, so the secondary line is only
    /// the split, and it carries Claude.
    func testWithoutTodayTheSecondaryLineIsTheSplitWithClaude() {
        let claude = subscription("claude", name: "Claude")
        XCTAssertEqual(
            OMCostTile.secondary(services: [claude], today: [:], week: ["claude": 35], locale: us),
            "Claude $35.00"
        )
    }
}
