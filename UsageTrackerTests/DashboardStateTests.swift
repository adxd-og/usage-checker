import XCTest
@testable import Omelette

/// `DashboardState`'s pure rules. The state object reads `AppState.shared`, so what is
/// tested is the selection it hands that snapshot to. Cloud session credits spec,
/// coordinator ruling: every percent surface answers from the plan's windows, the
/// burn-rate line under the Overview ring included.
final class DashboardStateTests: XCTestCase {
    func testTheBurnRateNeverPredictsACloudSessionCreditPool() {
        // No session window: the fullest window is predicted, and the pool at 92 % is
        // money, not a limit to run into.
        let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly)
        let service = Fixture.snapshot(id: "claude", buckets: [weekly, Fixture.cloudCredits])
        XCTAssertEqual(DashboardState.burnBucket(of: service)?.id, "seven_day")
        XCTAssertNil(
            DashboardState.burnBucket(of: Fixture.snapshot(id: "claude", buckets: [Fixture.cloudCredits])),
            "nothing to predict when the pool is all there is"
        )
    }

    func testTheSessionWindowIsPredictedWhenThereIsOne() {
        let session = Fixture.bucket(id: "five_hour", percent: 7, kind: .session)
        let service = Fixture.snapshot(id: "claude", buckets: [session, Fixture.cloudCredits])
        XCTAssertEqual(DashboardState.burnBucket(of: service)?.id, "five_hour")
    }
}
