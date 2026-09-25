import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens: "ok — gauges, On track". A 3.0 gauge
/// keeps the three bands every 2.x gauge draws (`usageStatusColor`) and takes their
/// colours from the tokens.
final class OMGaugeToneTests: XCTestCase {
    func testTheBandsSplitAtSeventyAndNinety() {
        XCTAssertEqual(OMGaugeTone.forUsed(0), .ok)
        XCTAssertEqual(OMGaugeTone.forUsed(69.9), .ok)
        XCTAssertEqual(OMGaugeTone.forUsed(70), .warning)
        XCTAssertEqual(OMGaugeTone.forUsed(89.9), .warning)
        XCTAssertEqual(OMGaugeTone.forUsed(90), .critical)
        XCTAssertEqual(OMGaugeTone.forUsed(137), .critical)
    }

    func testTheBandsAreTheOnesUsageStatusColorDraws() {
        let colour: [OMGaugeTone: Color] = [.ok: .green, .warning: .orange, .critical: .red]
        for percent in stride(from: 0.0, through: 100.0, by: 0.5) {
            XCTAssertEqual(colour[OMGaugeTone.forUsed(percent)], usageStatusColor(percent), "\(percent)")
        }
    }

    func testFillsAreTheOkWarningAndCriticalTokens() {
        XCTAssertEqual(OMGaugeTone.ok.fill, .ok)
        XCTAssertEqual(OMGaugeTone.warning.fill, .warning)
        XCTAssertEqual(OMGaugeTone.critical.fill, .critical)
    }

    func testOnTrackTextIsTheBrighterGreen() {
        XCTAssertEqual(OMGaugeTone.ok.text, .okText)
        XCTAssertEqual(OMGaugeTone.warning.text, .warning)
        XCTAssertEqual(OMGaugeTone.critical.text, .critical)
    }
}
