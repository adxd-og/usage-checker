import XCTest
@testable import Omelette

/// Independent verification of `FloatingMiniLayout.content(for:)`'s no-window branches
/// and `CostCopy.lastSevenDays`, from the spec rather than from the executor's own
/// `FloatingMiniPayAsYouGoTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "Floating panel: `.ok` + `weekCost > 0` + no hero → cost-only content through a
/// `CostCopy` rule; non-ok states show their state message, never 'haven't used'";
/// report D § 6. Claims under test: a healthy pay-as-you-go service with spend and no
/// windows gets its spend and never "haven't used"; a failed one gets its state
/// message; a healthy empty one keeps "haven't used".
final class FloatingMiniLayoutVerificationTests: XCTestCase {
    // MARK: - Healthy, pay-as-you-go, has spent money: never "haven't used"

    func testAHealthyPayAsYouGoAccountWithSpendShowsTheSpendNotHaventUsed() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 47.19, state: .ok)
        )
        XCTAssertEqual(content.weekCost, 47.19)
        XCTAssertNil(content.emptyText)
        XCTAssertNil(content.hero)
        XCTAssertTrue(content.rows.isEmpty)
    }

    func testTheSpendLineNeverMentionsHaventUsed() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 0.01, state: .ok)
        )
        XCTAssertNotNil(content.weekCost)
        let text = content.emptyText ?? ""
        XCTAssertFalse(text.contains("haven't used"))
    }

    func testExactlyZeroWeekCostDoesNotCountAsSpend() {
        // The rule is `weekCost > 0`, not `weekCost != nil`. A snapshot that reports a
        // week cost of precisely zero has not, in fact, spent anything.
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 0, state: .ok)
        )
        XCTAssertNil(content.weekCost)
        XCTAssertEqual(content.emptyText, "You haven't used Claude yet")
    }

    func testANilWeekCostIsAlsoNotSpend() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: nil, state: .ok)
        )
        XCTAssertNil(content.weekCost)
        XCTAssertEqual(content.emptyText, "You haven't used Claude yet")
    }

    // MARK: - Failed: state message, never spend, never "haven't used"

    func testAFailedServiceWithMoneyOnTheBooksStillShowsItsFailureNotTheSpend() {
        // A stale weekCost from a previous good poll must not be shown as if the spend
        // figure were current on a failed poll.
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "claude", buckets: [], weekCost: 99.99, state: .error, stateMessage: "Connection timed out")
        )
        XCTAssertNil(content.weekCost)
        XCTAssertEqual(content.emptyText, "Connection timed out")
    }

    func testEachNonOkStateGetsItsOwnMessageAndNeverHaventUsed() {
        let cases: [(ServiceState, String?, String)] = [
            (.notSignedIn, "Run `claude login` to sign in", "Run `claude login` to sign in"),
            (.notRunning, nil, RetainedCopy.chipText(for: .notRunning)),
            (.error, "HTTP 503", "HTTP 503"),
        ]
        for (state, message, expected) in cases {
            let content = FloatingMiniLayout.content(
                for: Fixture.snapshot(id: "claude", buckets: [], state: state, stateMessage: message)
            )
            XCTAssertEqual(content.emptyText, expected, "\(state)")
            XCTAssertNil(content.weekCost, "\(state)")
            XCTAssertFalse((content.emptyText ?? "").contains("haven't used"), "\(state)")
        }
    }

    func testAWhitespaceOnlyMessageFallsBackToTheChipWord() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn, stateMessage: "   ")
        )
        XCTAssertEqual(content.emptyText, RetainedCopy.chipText(for: .notSignedIn))
    }

    // MARK: - Healthy, nothing at all: keeps "haven't used"

    func testAHealthyServiceWithNoWindowsAndNoSpendKeepsHaventUsed() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "grok", buckets: [], weekCost: nil, state: .ok)
        )
        XCTAssertEqual(content.emptyText, "You haven't used Grok yet")
        XCTAssertNil(content.weekCost)
    }

    func testTheEmptySentenceNamesTheService() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "gemini", displayName: "Antigravity", buckets: [], state: .ok)
        )
        XCTAssertEqual(content.emptyText, "You haven't used Antigravity yet")
    }

    /// A service that does have a window must never fall into the no-window branch at
    /// all, spend or no spend — the hero ring wins.
    func testAServiceWithAWindowNeverGoesThroughTheNoWindowBranch() {
        let content = FloatingMiniLayout.content(
            for: Fixture.snapshot(
                id: "claude",
                buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 12, kind: .session)],
                weekCost: 500,
                state: .ok
            )
        )
        XCTAssertNotNil(content.hero)
        XCTAssertNil(content.weekCost)
        XCTAssertNil(content.emptyText)
    }

    // MARK: - CostCopy.lastSevenDays

    func testLastSevenDaysFormatsToTwoDecimalPlaces() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(CostCopy.lastSevenDays(47.19, locale: us), "Last 7 days $47.19")
        XCTAssertEqual(CostCopy.lastSevenDays(0.004, locale: us), "Last 7 days $0.00")
        XCTAssertEqual(CostCopy.lastSevenDays(0.006, locale: us), "Last 7 days $0.01")
        XCTAssertEqual(CostCopy.lastSevenDays(3, locale: us), "Last 7 days $3.00")
        // Session ruling 2026-09-24: the panel prints what the tile prints, so an
        // exact half cent rounds the way the tile's currency style rounds it.
        XCTAssertEqual(CostCopy.lastSevenDays(0.005, locale: us), "Last 7 days " + OMCostTile.money(0.005, locale: us))
    }

    func testLastSevenDaysHasNoApiEquivalentCaption() {
        // Documented rule: an account with no window of its own is pay-as-you-go, and
        // there the dollars are the real bill, so the string carries no disclaimer.
        let text = CostCopy.lastSevenDays(10)
        XCTAssertFalse(text.contains("API-equivalent"))
    }
}
