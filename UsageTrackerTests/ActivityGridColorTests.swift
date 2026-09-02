import XCTest
import SwiftUI
@testable import Omelette

/// The heat map's colour rule. Dollars have no "too much" level, so they stay on one
/// accent ramp; a quota square is a utilisation and gets the battery colours, which is
/// what makes a 95 % day read as red instead of "a slightly darker blue".
final class ActivityGridColorTests: XCTestCase {
    func testCostSquaresStayOnTheAccentRamp() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.5, usesStatusColor: false, unobserved: false), Color.accentColor)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 1.0, usesStatusColor: false, unobserved: false), Color.accentColor)
    }

    func testQuotaSquaresUseTheBatteryColours() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.5, usesStatusColor: true, unobserved: false), Color.green)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.75, usesStatusColor: true, unobserved: false), Color.orange)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.95, usesStatusColor: true, unobserved: false), Color.red)
    }

    func testAnObservedZeroAndAnUnobservedDayAreBothGrey() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0, usesStatusColor: true, unobserved: false), Color.secondary)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.9, usesStatusColor: true, unobserved: true), Color.secondary)
    }

    func testAnUnobservedDayIsFainterThanAnEmptyOne() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0.9, unobserved: true), 0.05, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0, unobserved: false), 0.12, accuracy: 0.0001)
    }

    func testTheRampRunsFromAFifthToFull() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0.5, unobserved: false), 0.60, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 1, unobserved: false), 1.00, accuracy: 0.0001)
    }

    func testIntensityIsClampedRatherThanTrusted() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 4, unobserved: false), 1.00, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: -1, usesStatusColor: true, unobserved: false), Color.secondary)
    }
}
