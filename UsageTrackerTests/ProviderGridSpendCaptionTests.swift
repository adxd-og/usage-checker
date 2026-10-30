import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3, decisions moved out of views: the cost caption. A
/// provider page says once that its dollars are API-equivalent, only when the week has
/// dollars, and never for a pay-as-you-go account, whose dollars are the bill.
final class ProviderGridSpendCaptionTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 53, kind: .session)

    func testASubscriptionsDollarsGetTheAPIEquivalentLine() {
        let claude = Fixture.snapshot(id: "claude", buckets: [session], weekCost: 41.37)
        XCTAssertEqual(ProviderGridRules.spendCaption(for: claude), CostCopy.apiEquivalent)
    }

    func testPayAsYouGoDollarsAreTheBill() {
        let grok = Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: 6.41)
        XCTAssertNil(ProviderGridRules.spendCaption(for: grok))
    }

    func testNoDollarsNoLine() {
        XCTAssertNil(ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", buckets: [session], weekCost: 0)))
        XCTAssertNil(ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", buckets: [session], weekCost: nil)))
    }

    func testASignedOutSubscriptionKeepsTheLine() {
        // No windows, but not answering: not known to be pay-as-you-go.
        let signedOut = Fixture.snapshot(id: "claude", weekCost: 12, state: .notSignedIn)
        XCTAssertEqual(ProviderGridRules.spendCaption(for: signedOut), CostCopy.apiEquivalent)
    }
}
