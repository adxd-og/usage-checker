import XCTest
import SwiftUI
@testable import Omelette

final class WindowRankingTests: XCTestCase {
    // MARK: usageStatusColor
    func testStatusColorIsGreenWhenComfortable() {
        XCTAssertEqual(usageStatusColor(0), .green)
        XCTAssertEqual(usageStatusColor(69.9), .green)
    }
    func testStatusColorIsOrangeFrom70() {
        XCTAssertEqual(usageStatusColor(70), .orange)
        XCTAssertEqual(usageStatusColor(89.9), .orange)
    }
    func testStatusColorIsRedFrom90() {
        XCTAssertEqual(usageStatusColor(90), .red)
        XCTAssertEqual(usageStatusColor(150), .red)
    }
}
