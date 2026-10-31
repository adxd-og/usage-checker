import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7: "Onboarding gains one step with the same picker", before the
/// last page, which finishes the tour (plan OWNER 10).
final class OnboardingPageTests: XCTestCase {
    func testThePetStepComesBeforeTheLastPage() {
        XCTAssertEqual(OnboardingPage.allCases, [.welcome, .permissions, .agents, .pet, .ready])
    }
}
