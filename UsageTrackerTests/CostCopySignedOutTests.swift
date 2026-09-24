import XCTest
@testable import Omelette

/// Whole-branch review of 2.7.0 (Codex, 2026-09-24): no windows is pay-as-you-go only while reporting.
final class CostCopySignedOutTests: XCTestCase {
    /// A subscription that is signed out or failing has no windows either; its local
    /// dollars keep the API-equivalent caption instead of being called a bill.
    func testASignedOutAccountWithNoWindowsIsNotCalledPayAsYouGo() {
        let signedOut = Fixture.snapshot(id: "claude", buckets: [], state: .notSignedIn)
        XCTAssertFalse(CostCopy.isPayAsYouGo(signedOut))
        XCTAssertNotNil(CostCopy.apiEquivalentCaption(for: signedOut))
        let failing = Fixture.snapshot(id: "claude", buckets: [], state: .error, stateMessage: "500")
        XCTAssertFalse(CostCopy.isPayAsYouGo(failing))
        let healthyNoWindows = Fixture.snapshot(id: "claude", buckets: [], weekCost: 12.5)
        XCTAssertTrue(CostCopy.isPayAsYouGo(healthyNoWindows), "a healthy account with no window is pay-as-you-go")
        XCTAssertNil(CostCopy.apiEquivalentCaption(for: healthyNoWindows))
    }
}
