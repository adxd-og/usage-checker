import SwiftUI
import XCTest
@testable import Omelette

/// The Insights tab's measures and colours against `Dashboard-Insights(-Light).dc.html`
/// (liquid-glass spec § Screens, "Insights"), and how its first row splits.
final class InsightsLookTests: XCTestCase {
    /// The mockup's blue, violet and teal, in both themes: the input, cache-write and
    /// cache-read token colours.
    func testTheModelSplitIsTheMockupsBlueVioletAndTeal() {
        XCTAssertEqual(
            InsightsMetrics.modelSplitTokens.map { OMPalette.rgba($0, scheme: .dark) },
            [OMRGBA(hex: 0x7AA2FF), OMRGBA(hex: 0xC79BFF), OMRGBA(hex: 0x5CC8C8)]
        )
        XCTAssertEqual(
            InsightsMetrics.modelSplitTokens.map { OMPalette.rgba($0, scheme: .light) },
            [OMRGBA(hex: 0x4C7EF3), OMRGBA(hex: 0x9A66EE), OMRGBA(hex: 0x26A8A8)]
        )
        XCTAssertEqual(InsightsMetrics.modelSplitToken(at: 1), .tokenCacheWrite)
        XCTAssertEqual(InsightsMetrics.modelSplitToken(at: 3), .tokenInput)
    }

    func testTheSplitBarAndLegendAreTheMockups() {
        XCTAssertEqual(InsightsMetrics.splitBarHeight, 10)
        XCTAssertEqual(InsightsMetrics.splitBarRadius, 5)
        XCTAssertEqual(InsightsMetrics.splitBarGap, 2)
        XCTAssertEqual(InsightsMetrics.legendSpacing, 22)
        XCTAssertEqual(InsightsMetrics.legendItemSpacing, 7)
        XCTAssertEqual(InsightsMetrics.legendDotSize, 8)
        XCTAssertEqual(InsightsMetrics.legendTextSize, 12.5)
    }

    /// "Other" is many models and none in particular: the muted mark, not a palette colour.
    func testTheOtherSliceIsMuted() {
        let other = InsightsModelShare(model: "Other", cost: 1, fraction: 0.1, isOther: true)
        let named = InsightsModelShare(model: "Opus 5", cost: 9, fraction: 0.9, isOther: false)

        XCTAssertEqual(InsightsMetrics.otherModelsToken, .muted)
        XCTAssertEqual(InsightsMetrics.splitToken(for: other, at: 2), .muted)
        XCTAssertEqual(InsightsMetrics.splitToken(for: named, at: 2), .tokenCacheRead)
        XCTAssertEqual(InsightsMetrics.splitToken(for: named, at: 0), .tokenInput)
    }
}
