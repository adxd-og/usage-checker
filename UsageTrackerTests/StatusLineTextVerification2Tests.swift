import XCTest
@testable import Omelette

/// Independent verification of `StatusLineText.todayCostText`'s `≈` marker, derived
/// from `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)": "StatusLineText a short marker, as a separate rule function".
/// Not from `StatusLineTextTests`. Focus: the marker leads the figure rather than
/// trailing it (unlike `StatusText`'s suffix), it only ever appears for `true`, and it
/// composes correctly with `render`'s "$0.00 today is hidden" rule.
final class StatusLineTextVerification2Tests: XCTestCase {
    private func service(today: Double?, apiEquivalent: Bool?) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
            plan: nil, windows: [], todayCost: today, weekCost: nil,
            todayTokens: nil, apiEquivalent: apiEquivalent
        )
    }

    func testTheMarkerIsASingleCharacterInFrontOfTheDollarSign() throws {
        XCTAssertEqual(StatusLineText.apiEquivalentMarker, "≈")
        let text = try XCTUnwrap(StatusLineText.todayCostText(service(today: 12.5, apiEquivalent: true)))
        XCTAssertTrue(text.hasPrefix("≈$"), text)
        XCTAssertFalse(text.hasSuffix("≈"), "not a trailing mark like StatusText's suffix")
    }

    func testFalseAndNilBothOmitTheMarker() {
        let falseText = StatusLineText.todayCostText(service(today: 12.5, apiEquivalent: false))
        let nilText = StatusLineText.todayCostText(service(today: 12.5, apiEquivalent: nil))
        XCTAssertEqual(falseText, "$12.50 today")
        XCTAssertEqual(nilText, "$12.50 today")
        XCTAssertFalse(falseText?.contains("≈") ?? true)
    }

    /// Nothing spent today is still nothing to show, marker or not.
    func testZeroTodayIsNilRegardlessOfTheFlag() {
        XCTAssertNil(StatusLineText.todayCostText(service(today: 0, apiEquivalent: true)))
        XCTAssertNil(StatusLineText.todayCostText(service(today: nil, apiEquivalent: true)))
    }

    /// The guard is `today > 0`, not `!= 0`: a negative figure is treated the same as
    /// nothing spent, marker or not.
    func testANegativeFigureIsAlsoNil() {
        XCTAssertNil(StatusLineText.todayCostText(service(today: -1.5, apiEquivalent: true)))
    }
}
