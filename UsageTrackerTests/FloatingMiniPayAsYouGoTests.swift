import XCTest
@testable import Omelette

/// The floating panel for a provider with no window to ring. "You haven't used … yet"
/// was the only thing it could say, and it is true in just one of three cases. A paying
/// pay-as-you-go account with no budget set publishes no window
/// (`AppState.applyPayAsYouGo`) but has the week's spend, which the All tab's tile
/// already shows as "Last 7 days $X". A provider that failed has its own message. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — Floating panel; report D § 6.
final class FloatingMiniPayAsYouGoTests: XCTestCase {
    func testAPayingPayAsYouGoAccountSeesItsSpendNotHaventUsed() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 12.5, state: .ok)
        )
        XCTAssertNil(content.hero)
        XCTAssertTrue(content.rows.isEmpty)
        XCTAssertNil(content.emptyText)
        XCTAssertEqual(content.weekCost, 12.5)
    }

    func testTheSpendLineUsesTheTilesWords() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(CostCopy.lastSevenDays(12.5, locale: us), "Last 7 days $12.50")
        XCTAssertEqual(CostCopy.lastSevenDays(1_234.567, locale: us), "Last 7 days $1,234.57")
    }

    func testTheSpendLineFollowsTheUsersLocaleLikeTheTile() {
        // The tile prints `.currency(code: "USD")` in the viewer's locale, and the panel
        // must not print the same week differently. German puts the sign last, after a
        // no-break space.
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(CostCopy.lastSevenDays(1_234.567, locale: de), "Last 7 days 1.234,57\u{00A0}$")
        XCTAssertEqual(
            CostCopy.lastSevenDays(1_234.567, locale: de),
            "Last 7 days \(OMCostTile.money(1_234.567, locale: de))"
        )
    }

    func testAHealthyAccountThatSpentNothingIsStillUnused() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 0, state: .ok)
        )
        XCTAssertEqual(content.emptyText, "You haven't used Claude yet")
        XCTAssertNil(content.weekCost)
    }

    func testASignedOutProviderSaysSoInItsOwnWords() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn, stateMessage: "Run `codex login` to sign in")
        )
        XCTAssertEqual(content.emptyText, "Run `codex login` to sign in")
        XCTAssertNil(content.weekCost)
    }

    func testAProviderThatGaveNoMessageGetsTheChipsWord() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "antigravity", buckets: [], state: .notRunning, stateMessage: nil)
        )
        XCTAssertEqual(content.emptyText, "Not running")
    }

    func testABlankMessageFallsBackToTheChipsWord() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "grok", buckets: [], state: .error, stateMessage: "  \n ")
        )
        XCTAssertEqual(content.emptyText, "Error")
    }

    func testAFailedPayAsYouGoPollShowsTheFailureNotTheSpend() {
        // `.ok` is what makes the spend this poll's. A failed poll's figure is not.
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 12.5, state: .error, stateMessage: "HTTP 500")
        )
        XCTAssertEqual(content.emptyText, "HTTP 500")
        XCTAssertNil(content.weekCost)
    }

    func testNoFailedStateEverSaysHaventUsed() {
        for state in [ServiceState.notSignedIn, .notRunning, .error] {
            let text = FloatingMiniLayout.content(
                for: Fixture.snapshot(id: "claude", buckets: [], state: state)
            ).emptyText ?? ""
            XCTAssertFalse(text.contains("haven't used"), "\(state): \(text)")
            XCTAssertFalse(text.isEmpty, "\(state) must say something")
        }
    }

    func testAServiceWithAWindowKeepsItsRingAndNoSpendLine() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(
                id: "claude",
                buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 37, kind: .session)],
                weekCost: 31.7
            )
        )
        XCTAssertEqual(content.hero?.id, "five_hour")
        XCTAssertNil(content.weekCost, "the ring is the panel's number; the spend stays on the tile")
        XCTAssertNil(content.emptyText)
    }
}
