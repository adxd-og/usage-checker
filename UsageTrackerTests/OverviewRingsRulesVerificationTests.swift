import XCTest
@testable import Omelette

/// Independent verification of `OverviewRingsRules` against the liquid-glass spec
/// (§ Components, "Overview rings"; § Screens, "Overview") and the plan's rulings D1–D5,
/// D10 (`docs/superpowers/plans/2026-09-25-3.0-P3-overview.md`). Written without reading
/// `OverviewRingsRulesTests.swift` or `OverviewRingsEmphasisTests.swift`; different bucket
/// shapes and hit-test points than their worked examples.
final class OverviewRingsRulesVerificationTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private var now: Date { SessionFixture.now }

    // MARK: - D1: window order

    /// D1: "every window the provider reports, the provider tab's hero first
    /// (`WindowRanking.detailHero`, the session when there is one, else the most
    /// constrained window …), then the rest in the provider's order, promotional pools
    /// last."
    func testWindowsPutsTheSessionHeroFirstThenOthersThenPromotionalLast() {
        let promo = Fixture.bucket(id: "promo_pool", label: "Bonus", percent: 10, kind: .other)
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 40, kind: .weekly)
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 53, kind: .session)
        let model = Fixture.bucket(id: "fable_only", label: "Fable only", percent: 47, kind: .modelSpecific)
        // Deliberately scrambled input order: promo first, session buried.
        let service = Fixture.snapshot(buckets: [promo, weekly, model, session])

        let windows = OverviewRingsRules.windows(for: service)

        XCTAssertEqual(windows.map(\.bucket.id), ["five_hour", "seven_day", "fable_only", "promo_pool"],
                        "hero (session) must lead, promotional must trail, everything else keeps its order")
    }

    /// D1/S10: only the first three windows get a ring; a fourth and beyond are legend
    /// rows with no series colour.
    func testOnlyTheFirstThreeWindowsGetARingSeries() {
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 20, kind: .session)
        let b2 = Fixture.bucket(id: "seven_day", label: "All models", percent: 30, kind: .weekly)
        let b3 = Fixture.bucket(id: "fable_only", label: "Fable only", percent: 40, kind: .modelSpecific)
        let b4 = Fixture.bucket(id: "extra_1", label: "Extra window 1", percent: 50, kind: .other)
        let b5 = Fixture.bucket(id: "extra_2", label: "Extra window 2", percent: 60, kind: .other)
        let service = Fixture.snapshot(buckets: [session, b2, b3, b4, b5])

        let windows = OverviewRingsRules.windows(for: service)

        XCTAssertEqual(windows.count, 5, "every window is still a legend row")
        XCTAssertEqual(windows.map(\.series), [.seriesSession, .seriesAllModels, .seriesPerModel, nil, nil])
    }

    /// D1: with no session window, the hero is `WindowRanking.heroBucket` — the most
    /// constrained *core* window — not simply the first in `buckets`. Model-scoped windows
    /// do not compete for the hero unless they are all the account has
    /// (`WindowRanking.heroBucket`'s own rule), so both candidates here are core (weekly)
    /// windows.
    func testWindowsFallsBackToTheMostConstrainedCoreWindowWithNoSession() {
        let calmerWeekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 30, kind: .weekly)
        let tighterWeekly = Fixture.bucket(id: "seven_day_opus", label: "Opus weekly", percent: 90, kind: .weekly)
        let service = Fixture.snapshot(buckets: [calmerWeekly, tighterWeekly])

        let windows = OverviewRingsRules.windows(for: service)

        XCTAssertEqual(windows.first?.bucket.id, "seven_day_opus", "the worse core window leads when there is no session")
    }

    /// A model-scoped window never outranks a core window for the hero position, even at
    /// a much higher percent — `WindowRanking.heroBucket`'s rule, which `detailHero`
    /// inherits when there is no session.
    func testWindowsHeroIgnoresAModelScopedWindowWhenACoreWindowExists() {
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 30, kind: .weekly)
        let modelScoped = Fixture.bucket(id: "seven_day_fable", label: "Fable only", percent: 90, kind: .modelSpecific)
        let service = Fixture.snapshot(buckets: [weekly, modelScoped])

        let windows = OverviewRingsRules.windows(for: service)

        XCTAssertEqual(windows.first?.bucket.id, "seven_day",
                        "a model-scoped window does not compete for hero while a core window exists")
    }

    func testWindowsIsEmptyWithNoBuckets() {
        let service = Fixture.snapshot(buckets: [])
        XCTAssertTrue(OverviewRingsRules.windows(for: service).isEmpty)
    }

    // MARK: - D3: ring colour is position, not kind

    func testRingColourFollowsPositionNotWindowKind() {
        // Codex-shaped account: one weekly window only, no session.
        let onlyWeekly = Fixture.bucket(id: "weekly", label: "Weekly", percent: 12, kind: .weekly)
        let service = Fixture.snapshot(buckets: [onlyWeekly])
        let windows = OverviewRingsRules.windows(for: service)
        XCTAssertEqual(windows.first?.series, .seriesSession, "the outermost ring is always seriesSession, whatever the window's own kind")
    }

    // MARK: - D4: centre name

    func testCentreNameDropsCurrentFromCurrentSession() {
        XCTAssertEqual(OverviewRingsRules.centreName("Current session"), "session")
    }

    func testCentreNameLowercasesTheAllPrefix() {
        XCTAssertEqual(OverviewRingsRules.centreName("All models"), "all models")
    }

    func testCentreNameKeepsOtherLabelsVerbatim() {
        XCTAssertEqual(OverviewRingsRules.centreName("Fable only"), "Fable only")
        XCTAssertEqual(OverviewRingsRules.centreName("Opus"), "Opus", "a model name keeps its capital")
    }

    // MARK: - Centre figure fallback

    func testCentreShowsTheOutermostWindowWhenNothingIsEmphasised() {
        let a = OverviewRingWindow(bucket: Fixture.bucket(id: "a", label: "A", percent: 30), series: .seriesSession)
        let b = OverviewRingWindow(bucket: Fixture.bucket(id: "b", label: "B", percent: 80), series: .seriesAllModels)
        let centre = OverviewRingsRules.centre(windows: [a, b], emphasised: nil, mode: .used)
        XCTAssertEqual(centre?.name, "A")
        XCTAssertEqual(centre?.percent, "30%")
    }

    func testCentreFallsBackToOutermostWhenEmphasisedIndexNoLongerExists() {
        let a = OverviewRingWindow(bucket: Fixture.bucket(id: "a", label: "A", percent: 30), series: .seriesSession)
        let centre = OverviewRingsRules.centre(windows: [a], emphasised: 9, mode: .used)
        XCTAssertEqual(centre?.name, "A", "an index past the end of the list is not the emphasised window")
    }

    func testCentreIsNilWithNoWindows() {
        XCTAssertNil(OverviewRingsRules.centre(windows: [], emphasised: nil, mode: .used))
    }

    func testCentreRespectsPercentDisplayMode() {
        let a = OverviewRingWindow(bucket: Fixture.bucket(id: "a", label: "A", percent: 30), series: .seriesSession)
        let centre = OverviewRingsRules.centre(windows: [a], emphasised: 0, mode: .remaining)
        XCTAssertEqual(centre?.percent, "70%", "remaining mode counts down from 100")
    }

    // MARK: - D5: status text, nil when retained

    func testStatusIsNilWhenTheServiceIsRetained() {
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 53, kind: .session)
        let service = Fixture.snapshot(buckets: [session], state: .error)
        XCTAssertTrue(service.isRetained, "state != .ok with buckets present is the retained predicate")
        XCTAssertNil(OverviewRingsRules.status(for: service), "last-known numbers describe no present state (D5)")
    }

    func testStatusMatchesTheWorstCoreWindowsPhraseWhenLive() {
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 53, kind: .session)
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 91, kind: .weekly)
        let service = Fixture.snapshot(buckets: [session, weekly], state: .ok)
        let worst = WindowRanking.heroBucket(for: service)!
        let status = OverviewRingsRules.status(for: service)
        XCTAssertEqual(status?.text, OMHero.statusPhrase(worst.clampedPercent))
        XCTAssertEqual(status?.token, OMHero.statusToken(worst.clampedPercent))
    }

    // MARK: - D10: emphasis opacities

    func testEmphasisLeavesEveryoneAtFullOpacityWhenNothingIsHovered() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: nil, count: 3), [1, 1, 1])
    }

    func testEmphasisDimsEveryoneButTheHoveredWindowTo22Percent() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 1, count: 3), [0.22, 1, 0.22])
    }

    func testEmphasisIsAtRestWhenTheHoveredIndexIsOutOfRange() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 5, count: 3), [1, 1, 1],
                        "a stale index (the windows changed under the pointer) must not crash or dim everyone")
    }

    func testEmphasisIsEmptyWithNoWindows() {
        XCTAssertEqual(OverviewRingsRules.emphasis(hovered: 0, count: 0), [])
    }

    // MARK: - D10: pointer wins over focus, focus only under keyboard navigation

    func testPointerWinsOverKeyboardFocus() {
        XCTAssertEqual(OverviewRingsRules.emphasised(hovered: 2, focused: 0, keyboardNavigation: true), 2)
    }

    func testFocusIsIgnoredWithoutKeyboardNavigation() {
        XCTAssertNil(OverviewRingsRules.emphasised(hovered: nil, focused: 1, keyboardNavigation: false),
                     "a click must not leave a window stuck emphasised")
    }

    func testFocusEmphasisesUnderKeyboardNavigation() {
        XCTAssertEqual(OverviewRingsRules.emphasised(hovered: nil, focused: 1, keyboardNavigation: true), 1)
    }

    // MARK: - Ring hit testing

    func testRingHitTestingFindsTheExactRadiusOfEachRing() {
        let middle = OverviewRingsRules.diameter / 2
        for (index, radius) in OverviewRingsRules.radii.enumerated() {
            let point = CGPoint(x: middle, y: middle - radius)
            XCTAssertEqual(OverviewRingsRules.ring(at: point, count: 3), index,
                            "a point exactly on ring \(index)'s centre line must hit ring \(index)")
        }
    }

    /// With the radii spaced 21 pt apart and a 10.5 pt half-width, two neighbouring rings'
    /// hit zones exactly touch (`[95.5, 116.5]` for the outer ring, `[74.5, 95.5]` for the
    /// middle one) rather than leaving a gap; the shared boundary point belongs to the
    /// outer ring, since `ring(at:count:)` returns the first index that matches.
    func testRingHitTestingGivesTheSharedBoundaryToTheOuterRing() {
        let middle = OverviewRingsRules.diameter / 2
        let point = CGPoint(x: middle, y: middle - 95.5)
        XCTAssertEqual(OverviewRingsRules.ring(at: point, count: 3), 0)
    }

    func testRingHitTestingMissesJustOutsideTheOutermostRing() {
        let middle = OverviewRingsRules.diameter / 2
        // One point beyond the outer ring's hit zone (106 + 10.5).
        let point = CGPoint(x: middle, y: middle - 116.5 - 1)
        XCTAssertNil(OverviewRingsRules.ring(at: point, count: 3))
    }

    func testRingHitTestingIgnoresRingsPastCount() {
        let middle = OverviewRingsRules.diameter / 2
        let innerRingPoint = CGPoint(x: middle, y: middle - OverviewRingsRules.radii[2])
        XCTAssertNil(OverviewRingsRules.ring(at: innerRingPoint, count: 1),
                     "count limits which rings are actually drawn and hittable")
    }

    func testRingHitTestingMissesTheCentreHole() {
        let middle = OverviewRingsRules.diameter / 2
        XCTAssertNil(OverviewRingsRules.ring(at: CGPoint(x: middle, y: middle), count: 3))
    }

    // MARK: - Legend row hover: a late exit clears only its own row

    func testHoverEnteringARowSetsIt() {
        XCTAssertEqual(OverviewRingsRules.hover(inside: true, row: 2, current: nil), 2)
    }

    func testLeavingTheCurrentlyHoveredRowClearsIt() {
        XCTAssertNil(OverviewRingsRules.hover(inside: false, row: 1, current: 1))
    }

    func testLeavingAStaleRowDoesNotClearTheNewlyHoveredOne() {
        // The pointer already moved into row 2 before row 1's exit event lands.
        XCTAssertEqual(OverviewRingsRules.hover(inside: false, row: 1, current: 2), 2)
    }
}
