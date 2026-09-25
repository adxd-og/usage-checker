import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of package P1 (Popover) against
/// `docs/superpowers/specs/2026-09-24-liquid-glass-redesign.md` § Design → Screens
/// ("Popover · All", "Popover · provider"), § Packages → P1, and the session's
/// rulings (version link leaves the footer; the refresh *button* goes, ⌘R stays;
/// "Last known HH:mm" for every retained tile; warning/critical = system orange/red;
/// `OMSegmentedControl` gains `accessibilityLabel:` default "Provider" and
/// popover/dashboard metrics default dashboard).
///
/// Every fixture below is built through `Fixture.snapshot` / `Fixture.bucket`
/// (`UsageTrackerTests/Fixtures.swift`) — no test-only initializers.

// MARK: - Tiles (spec § Screens, "Popover · All")

final class PopoverTileSubtitleVerificationTests: XCTestCase {
    /// Principle 2: "No tinted chips under text. State is coloured text ... or a dot."
    /// A live provider with a plan shows the plan, in secondary — not its state.
    func testALiveProviderWithAPlanShowsThePlanNotItsState() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", percent: 10, kind: .session)],
            state: .ok
        )
        XCTAssertEqual(OMProviderTile.subtitle(for: service), OMColoredText(text: "Max 20x", token: .secondary))
    }

    /// A signed-out provider shows its state, in the warning token — never a chip.
    func testASignedOutProviderShowsSignInInWarning() {
        let service = Fixture.snapshot(id: "codex", displayName: "Codex", plan: nil, state: .notSignedIn)
        XCTAssertEqual(OMProviderTile.subtitle(for: service), OMColoredText(text: "Sign in", token: .warning))
    }

    /// A provider in error shows its state in the critical token.
    func testAFailedProviderShowsErrorInCritical() {
        let service = Fixture.snapshot(id: "codex", displayName: "Codex", state: .error)
        XCTAssertEqual(OMProviderTile.subtitle(for: service), OMColoredText(text: "Error", token: .critical))
    }

    /// An Enterprise account whose only signal is an enabled spend limit — no
    /// session or weekly buckets at all — must still show its plan, not "No data":
    /// `WindowRanking.heroBucket`'s synthetic extra-usage window makes it count as
    /// "has numbers" even with `buckets: []`. Built directly from `Fixture.snapshot`
    /// with an enabled `extraUsage` and empty buckets, per the brief.
    func testAnEnterpriseAccountWithOnlyASpendLimitShowsItsPlanNotNoData() {
        let service = Fixture.snapshot(
            id: "claude",
            displayName: "Claude",
            plan: "Claude Enterprise",
            buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 500, usedCredits: 120, utilization: 24),
            weekCost: nil,
            state: .ok
        )
        XCTAssertEqual(
            OMProviderTile.subtitle(for: service),
            OMColoredText(text: "Enterprise", token: .secondary),
            "an Enterprise account with a live spend limit and no windows must not read 'No data'"
        )
        // The mechanism the subtitle rule leans on: the synthetic spend-limit bucket
        // makes `detailHero` (and so `hasNumbers`) non-nil even with no real buckets.
        XCTAssertNotNil(WindowRanking.detailHero(for: service))
        XCTAssertEqual(WindowRanking.detailHero(for: service)?.id, WindowRanking.extraUsageBucketID(for: service))
    }

    /// The same account with the spend limit *disabled* (or absent) and no windows
    /// really has nothing to report, so "No data" is correct there.
    func testAnEnterpriseAccountWithNoSpendLimitAndNoWindowsReallyHasNoData() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Enterprise",
            buckets: [], extraUsage: nil, weekCost: nil, state: .ok
        )
        XCTAssertEqual(OMProviderTile.subtitle(for: service), OMColoredText(text: "No data", token: .secondary))
    }

    /// `stateToken` mapping backing the coloured text (Principle 2).
    func testStateTokenMapping() {
        XCTAssertEqual(OMProviderTile.stateToken(for: .notSignedIn), .warning)
        XCTAssertEqual(OMProviderTile.stateToken(for: .error), .critical)
        XCTAssertEqual(OMProviderTile.stateToken(for: .notRunning), .secondary)
        XCTAssertEqual(OMProviderTile.stateToken(for: .ok), .secondary)
    }
}

/// Spec § Screens, "Popover · All": "Antigravity shows 'Last known 12:50', no 'resets
/// now'" — and the session ruling that this applies to *every* retained tile, not
/// only Antigravity.
final class PopoverRetainedTileVerificationTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// A different provider than the spec's own Antigravity example (Codex, closed),
    /// to prove the rule is general and not special-cased on the id.
    func testAClosedCodexTileSaysLastKnownNotResetsNow() throws {
        let service = Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 44,
                                     resetsAt: moment(25, 9, 0), kind: .session)],
            state: .notRunning, stateMessage: "Codex isn't running",
            at: moment(25, 8, 15)
        )
        let hero = try XCTUnwrap(WindowRanking.tileHero(for: service))
        let now = moment(25, 11, 0)
        XCTAssertTrue(service.isRetained)
        // What the caption would have been before this rule existed.
        XCTAssertEqual(WindowRanking.remainingText(until: hero.resetsAt, now: now), "resets now")
        XCTAssertEqual(
            OMProviderTile.heroCaption(for: service, hero: hero, now: now, calendar: calendar, locale: locale),
            OMTileCaption(title: "Last known", value: "08:15")
        )
    }

    /// A *live* provider whose window has not reset yet keeps its countdown — the
    /// rule only fires once the service is retained, not on every expired window.
    func testALiveTileWithATimeStillKeepsItsCountdown() throws {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", percent: 30, resetsAt: moment(25, 12, 0), kind: .session)],
            state: .ok, at: moment(25, 10, 0)
        )
        let hero = try XCTUnwrap(WindowRanking.tileHero(for: service))
        XCTAssertFalse(service.isRetained)
        let caption = OMProviderTile.heroCaption(for: service, hero: hero, now: moment(25, 10, 0), calendar: calendar, locale: locale)
        XCTAssertNotEqual(caption.title, RetainedCopy.lastKnownTitle)
    }
}

// MARK: - Cost tile (spec § Screens, "Popover · All": "cost tile includes Claude +
// API-equivalent caption"; § Facts: "today-first, Claude included, API-equivalent caption")

final class PopoverCostTileVerificationTests: XCTestCase {
    /// Claude's dollars are not special-cased out of the tile: the "today" dict is
    /// keyed by service id like any other provider, and Claude's entry counts in the
    /// total, the breakdown and the accessibility label exactly like Codex's.
    func testClaudesTodayDollarsCountTowardTheHeadlineLikeAnyOtherProvider() throws {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude", weekCost: 40, state: .ok)
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", weekCost: 8, state: .ok)
        let today = ["claude": 12.5, "codex": 1.5]
        let withClaude = try XCTUnwrap(OMCostTile.todayTotal([claude, codex], today: today))
        XCTAssertEqual(withClaude, 14.0, accuracy: 0.001)
        // Drop Claude's entry: the headline must move, proving it was counted.
        let withoutClaude = try XCTUnwrap(OMCostTile.todayTotal([claude, codex], today: ["codex": 1.5]))
        XCTAssertEqual(withoutClaude, 1.5, accuracy: 0.001)
        XCTAssertTrue(OMCostTile.breakdown([claude, codex]).contains("Claude"))
    }

    /// "Today" leads once any provider has a today figure; the tile falls back to
    /// "Last 7 days" only when nothing is known yet.
    func testTitleIsTodayOnceAnyProviderHasATodayFigureOtherwiseLast7Days() {
        XCTAssertEqual(OMCostTile.title(todayKnown: true), "Today")
        XCTAssertEqual(OMCostTile.title(todayKnown: false), "Last 7 days")
    }

    /// The API-equivalent caption appears once any contributing provider (weekCost or
    /// today) is a subscription, and is silent when every contributor is pay-as-you-go
    /// or nobody has spent anything.
    func testAPIEquivalentCaptionFollowsWhetherAnyContributorIsASubscription() {
        // A subscription is a provider that reports a real rate-limit window
        // (`CostCopy.isPayAsYouGo`: empty buckets + `.ok` reads as pay-as-you-go).
        let claudeSub = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", percent: 10, kind: .session)],
            weekCost: 12, state: .ok
        )
        XCTAssertNotNil(OMCostTile.caption(services: [claudeSub]))

        // No dollars anywhere: nothing contributes, so there is nothing to caption.
        let noSpend = Fixture.snapshot(id: "claude", displayName: "Claude", weekCost: 0, state: .ok)
        XCTAssertNil(OMCostTile.caption(services: [noSpend], today: [:]))

        // A pay-as-you-go account (no windows, `.ok`) whose only dollars are today's:
        // it still contributes, but the caption stays silent — those dollars really
        // are the bill.
        XCTAssertNil(OMCostTile.caption(services: [noSpend], today: ["claude": 3.2]))

        // The same "today" figure from the subscription above does earn the caption.
        XCTAssertNotNil(OMCostTile.caption(services: [claudeSub], today: ["claude": 3.2]))
    }
}

// MARK: - Footer (spec § Screens, "Popover · All": "refresh button removed from the
// footer (⌘R stays as a shortcut); the footer's version link goes too")

final class PopoverFooterVerificationTests: XCTestCase {
    func testTheFooterHasNoRefreshActionAndNoVersionAction() {
        XCTAssertFalse(PopoverFooterRules.buttons.contains(.refresh))
        XCTAssertFalse(PopoverFooterRules.trailing.contains(.refresh))
        // There is no `.version` case at all in `PopoverAction` — a version link
        // cannot be reintroduced through the footer's own action enum.
        XCTAssertEqual(Set(PopoverAction.allCases), [.dashboard, .floatingWindow, .settings, .refresh, .quit])
    }

    /// Refresh is reachable *only* by keyboard.
    func testRefreshIsKeyboardOnly() {
        XCTAssertEqual(PopoverFooterRules.keyboardOnly, [.refresh])
        XCTAssertEqual(PopoverFooterRules.shortcutKey(.refresh), "r")
    }

    /// Quit is the only thing after the spacer (ruling: `trailing == [.quit]`).
    func testTrailingIsExactlyQuit() {
        XCTAssertEqual(PopoverFooterRules.trailing, [.quit])
    }

    /// The three glass buttons, left to right, in the mockup's order.
    func testTheGlassButtonsAreDashboardFloatingWindowSettingsInOrder() {
        XCTAssertEqual(PopoverFooterRules.buttons, [.dashboard, .floatingWindow, .settings])
    }
}

// MARK: - Popover body (spec § Tokens: "Radii: popover 24"; § Facts: "fixed 360 pt width")

final class PopoverBodyMetricsVerificationTests: XCTestCase {
    func testTheBodyIs360PointsWideWithA24PointCorner() {
        XCTAssertEqual(PopoverView.width, 360)
        XCTAssertEqual(OMRadius.corner(for: PopoverView.bodyCorner), .rounded(24))
    }

    func testTheBodyDrawsChromeGlass() {
        XCTAssertEqual(PopoverView.bodyGlass, .chrome)
    }
}

// MARK: - Provider tab (spec § Screens, "Popover · provider": "hero ring, weekly
// limits as bars, 'On track' as text")

final class PopoverProviderTabVerificationTests: XCTestCase {
    func testTheHeroRingIsSlimAndTheMockups116PointSize() {
        XCTAssertEqual(OMHero.ringStyle, .slim)
        XCTAssertEqual(OMRing.metrics(size: .hero, style: .slim).diameter, 116)
    }

    /// "On track" (Principle 2: state as coloured text) at the mid band, with the
    /// other three phrases at their boundaries — none of them a chip.
    func testStatusPhraseBandsIncludingOnTrack() {
        XCTAssertEqual(OMHero.statusPhrase(0), "Plenty of headroom")
        XCTAssertEqual(OMHero.statusPhrase(49.9), "Plenty of headroom")
        XCTAssertEqual(OMHero.statusPhrase(50), "On track")
        XCTAssertEqual(OMHero.statusPhrase(69.9), "On track")
        XCTAssertEqual(OMHero.statusPhrase(70), "Running hot")
        XCTAssertEqual(OMHero.statusPhrase(89.9), "Running hot")
        XCTAssertEqual(OMHero.statusPhrase(90), "Almost at the limit")
    }

    /// The status phrase's colour rides the same gauge-tone bands as the ring itself
    /// (ok/warning/critical, § Decisions: "warning/critical = system orange/red").
    func testStatusTokenFollowsTheGaugeToneBands() {
        XCTAssertEqual(OMHero.statusToken(10), OMGaugeTone.ok.text)
        XCTAssertEqual(OMHero.statusToken(75), OMGaugeTone.warning.text)
        XCTAssertEqual(OMHero.statusToken(95), OMGaugeTone.critical.text)
    }

    /// Warning/critical resolve to the system orange/red hexes, per the session ruling.
    func testWarningAndCriticalAreSystemOrangeAndRed() {
        // Apple's system orange / red hexes (dark and light variants).
        XCTAssertEqual(OMPalette.rgba(.warning, scheme: .dark), OMRGBA(hex: 0xFF9F0A))
        XCTAssertEqual(OMPalette.rgba(.warning, scheme: .light), OMRGBA(hex: 0xFF9500))
        XCTAssertEqual(OMPalette.rgba(.critical, scheme: .dark), OMRGBA(hex: 0xFF453A))
        XCTAssertEqual(OMPalette.rgba(.critical, scheme: .light), OMRGBA(hex: 0xFF3B30))
    }

    /// Weekly limits render as bars (`OMKeyValueRow`'s embedded `BarSegment`), in the
    /// 3.0 slim look, inside the provider tab's group card padding from the mockup.
    func testWeeklyLimitsGroupUsesTheMockups14PointPadding() {
        XCTAssertEqual(PopoverView.groupPadding, 14)
        XCTAssertEqual(PopoverView.groupSpacing, 14)
        XCTAssertEqual(OMKeyValueRow.barStyle, .slim)
    }
}

// MARK: - `OMSegmentedControl` (spec § Facts: "titles drop past four items ... popover
// picker is logo-only, dashboard keeps labels"; ruling: `accessibilityLabel:` default
// "Provider", popover/dashboard metrics default dashboard)

final class PopoverSegmentedControlVerificationTests: XCTestCase {
    @MainActor
    func testTheDefaultAccessibilityLabelIsProvider() {
        let control = OMSegmentedControl(
            items: [OMSegmentItem(id: "all", title: "All")],
            selection: .constant("all")
        )
        XCTAssertEqual(control.containerLabel, "Provider")
    }

    /// The dashboard's range picker (or any future caller) can name what the segments
    /// choose instead.
    @MainActor
    func testACallerCanNameWhatTheSegmentsChoose() {
        let control = OMSegmentedControl(
            items: [OMSegmentItem(id: "24h", title: "24h")],
            selection: .constant("24h"),
            accessibilityLabel: "Time range"
        )
        XCTAssertEqual(control.containerLabel, "Time range")
    }

    /// Dashboard is the default metrics (its call sites, written before this package,
    /// pass no `metrics:` at all).
    @MainActor
    func testDashboardMetricsAreTheDefault() {
        let control = OMSegmentedControl(items: [], selection: .constant(""))
        XCTAssertEqual(control.metrics, .dashboard)
    }

    /// The popover explicitly opts into its own, narrower metrics.
    @MainActor
    func testThePopoverPassesItsOwnMetricsExplicitly() {
        let control = OMSegmentedControl(items: [], selection: .constant(""), metrics: .popover)
        XCTAssertEqual(control.metrics, .popover)
        XCTAssertEqual(control.metrics.height, 30)
        XCTAssertTrue(control.metrics.fillsWidth)
    }

    /// Titles disappear past four items unless the surface always wants them
    /// (unchanged rule; the popover picker is logo-only above four providers).
    func testShowsTitlesRuleIsUnchanged() {
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 4, alwaysShowsTitles: false))
        XCTAssertFalse(OMSegmentedControl.showsTitles(count: 5, alwaysShowsTitles: false))
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 5, alwaysShowsTitles: true))
    }
}
