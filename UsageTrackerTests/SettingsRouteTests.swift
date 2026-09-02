import XCTest
@testable import Omelette

@MainActor
final class SettingsRouteTests: XCTestCase {
    func testConsumeReturnsTheRequestOnceAndThenNothing() {
        let route = SettingsRoute()
        XCTAssertNil(route.consumePendingTab())
        route.pendingTab = SettingsRoute.agentsTab
        XCTAssertEqual(route.consumePendingTab(), "Agents")
        XCTAssertNil(route.consumePendingTab())
        XCTAssertNil(route.pendingTab)
    }
}
