import XCTest
@testable import Omelette

/// Independent verification of `SessionCopy.rowActionName(expanded:)`, from the spec
/// rather than from the executor's own `SessionRowActionTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "the row's chevron + title become a `Button(.plain)` with
/// `SessionCopy.rowActionName(expanded:)`"; report D § 4. Claim under test: the row
/// action names differ for expanded and collapsed.
final class SessionCopyRowActionVerificationTests: XCTestCase {
    func testTheTwoStatesReadDifferently() {
        XCTAssertNotEqual(
            SessionCopy.rowActionName(expanded: true),
            SessionCopy.rowActionName(expanded: false)
        )
    }

    func testCollapsedOffersToOpenIt() {
        let name = SessionCopy.rowActionName(expanded: false)
        XCTAssertTrue(name.lowercased().contains("show"), name)
        XCTAssertFalse(name.lowercased().contains("hide"), name)
    }

    func testExpandedOffersToCloseIt() {
        let name = SessionCopy.rowActionName(expanded: true)
        XCTAssertTrue(name.lowercased().contains("hide"), name)
        XCTAssertFalse(name.lowercased().contains("show"), name)
    }

    /// The name is used both as the VoiceOver hint and the pointer tooltip
    /// (`.help`/`.accessibilityHint` in `SessionRowView.rowToggle`), so it must be a
    /// stable, deterministic function of `expanded` alone — calling it twice with the
    /// same input must not depend on any other state.
    func testItIsPureInTheExpandedFlagAlone() {
        XCTAssertEqual(SessionCopy.rowActionName(expanded: true), SessionCopy.rowActionName(expanded: true))
        XCTAssertEqual(SessionCopy.rowActionName(expanded: false), SessionCopy.rowActionName(expanded: false))
    }
}
