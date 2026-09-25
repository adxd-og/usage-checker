import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of `OverviewCopy.subtitle` (liquid-glass spec § Screens,
/// "Overview": the header reads "Max 20x · updated 7s ago") and of the `dashboardCard`
/// restyle (§ Tokens, "pane glass", dashboard-card radius 22; session ruling "the
/// signature unchanged"). Written without reading `OverviewHeaderCopyTests.swift` or
/// `DashboardCardStyleTests.swift`.
final class OverviewCopyVerificationTests: XCTestCase {
    private var now: Date { SessionFixture.now }

    // MARK: - subtitle: with a plan

    func testSubtitleCombinesThePlanAndTheLowercasedUpdatedLine() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Claude Max 20x", state: .ok)
        let fetchedAt = now.addingTimeInterval(-7)
        let subtitle = OverviewCopy.subtitle(service: service, snapshotFetchedAt: fetchedAt, now: now)
        XCTAssertEqual(subtitle, "Max 20x · updated 7s ago")
    }

    // MARK: - subtitle: without a plan

    func testSubtitleWithNoPlanIsJustTheUpdatedLineUnmodified() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", plan: nil, state: .ok)
        let fetchedAt = now.addingTimeInterval(-7)
        let subtitle = OverviewCopy.subtitle(service: service, snapshotFetchedAt: fetchedAt, now: now)
        XCTAssertEqual(subtitle, "Updated 7s ago", "with no plan line the capital U must survive")
    }

    func testSubtitleIsNilWhenTheServiceIsMissingFromTheSnapshot() {
        XCTAssertNil(OverviewCopy.subtitle(service: nil, snapshotFetchedAt: now, now: now))
    }

    // MARK: - live vs. retained: which timestamp ages the subtitle

    func testALiveServiceAgesBySnapshotFetchedAtNotItsOwnStaleTimestamp() {
        let staleOwnTimestamp = now.addingTimeInterval(-9_000) // would read "2h ago"
        let service = Fixture.snapshot(id: "claude", plan: nil, state: .ok, at: staleOwnTimestamp)
        let freshSnapshotFetchedAt = now.addingTimeInterval(-7)
        let subtitle = OverviewCopy.subtitle(service: service, snapshotFetchedAt: freshSnapshotFetchedAt, now: now)
        XCTAssertEqual(subtitle, "Updated 7s ago", "a live provider's age is the poll's, not its own last write")
    }

    func testARetainedServiceAgesByItsOwnFetchedAtNotTheLiveSnapshot() {
        let ownFetchedAt = now.addingTimeInterval(-9_000) // "2h ago"
        let service = Fixture.snapshot(
            id: "antigravity",
            plan: nil,
            buckets: [Fixture.bucket(id: "b", percent: 10)],
            state: .notRunning, at: ownFetchedAt
        )
        XCTAssertTrue(service.isRetained)
        let liveSnapshotFetchedAt = now.addingTimeInterval(-7)
        let subtitle = OverviewCopy.subtitle(service: service, snapshotFetchedAt: liveSnapshotFetchedAt, now: now)
        XCTAssertEqual(subtitle, "Updated 2h ago", "last-known numbers are as old as their own reading")
    }

    // MARK: - the legend's footer line

    func testFooterUsesTheBurnVerdictsColourWhenThereIsOne() {
        let verdict = BurnVerdict(willHit: true, text: "At this pace, limit in ~1h 40m")
        let footer = OverviewCopy.footer(verdict: verdict, burn: nil, retained: false)
        XCTAssertEqual(footer.text, verdict.text)
        XCTAssertEqual(footer.token, OMHero.verdictToken(verdict))
        XCTAssertEqual(footer.token, .warning, "a verdict that will hit the limit reads amber")
    }

    func testFooterFallsBackToTheLowercasedBurnLineWithNoVerdict() {
        let footer = OverviewCopy.footer(verdict: nil, burn: nil, retained: false)
        XCTAssertEqual(footer.text, "Burn rate: not enough data")
        XCTAssertEqual(footer.token, .secondary)
    }

    // MARK: - dashboardCard restyle: pane glass, 22 pt corner, signature unchanged

    func testDashboardCardIsPaneGlassInTheDashboardCardCorner() {
        XCTAssertEqual(DashboardCardRules.surface, .pane)
        XCTAssertEqual(DashboardCardRules.corner, .dashboardCard)
        XCTAssertEqual(OMRadius.corner(for: .dashboardCard), .rounded(22))
    }

    /// The plan requires `dashboardCard(padding:)`'s signature to stay frozen so every
    /// existing caller across the app keeps compiling. This is a compile-time check: if
    /// the signature (including the default argument) changed incompatibly, the suite
    /// would fail to build before this test could even run.
    @MainActor
    func testDashboardCardStillTakesAnOptionalPaddingArgument() {
        _ = EmptyView().dashboardCard()
        _ = EmptyView().dashboardCard(padding: 10)
        XCTAssertTrue(true)
    }
}
