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

    func testTheCardsAreTheMockups() {
        XCTAssertEqual(InsightsMetrics.gap, 20)
        // DashboardHeader pads 12 pt under itself; the mockup's cards start 20 pt below it.
        XCTAssertEqual(InsightsMetrics.headerGap + 12, 20)
        XCTAssertEqual(InsightsMetrics.columnBottom, 32)
        XCTAssertEqual(InsightsMetrics.sessionCardVerticalPadding, 22)
        XCTAssertEqual(InsightsMetrics.sessionCardHorizontalPadding, 26)
        XCTAssertEqual(InsightsMetrics.figureCardVerticalPadding, 22)
        XCTAssertEqual(InsightsMetrics.figureCardHorizontalPadding, 24)
        XCTAssertEqual(InsightsMetrics.stripVerticalPadding, 20)
        XCTAssertEqual(InsightsMetrics.stripHorizontalPadding, 24)
        XCTAssertEqual(InsightsMetrics.stripColumnGap, 24)
        XCTAssertEqual(InsightsMetrics.stripDividerWidth, 1)
    }

    func testTheFiguresAreTheMockups() {
        XCTAssertEqual(InsightsMetrics.figureTitleSize, 12.5)
        XCTAssertEqual(InsightsMetrics.figureSpacing, 3)
        XCTAssertEqual(InsightsMetrics.cardValueSize, 30)
        XCTAssertEqual(InsightsMetrics.stripValueSize, 24)
        XCTAssertEqual(InsightsMetrics.figureValueTracking, -0.5)
        XCTAssertEqual(InsightsMetrics.deltaSize, 13)
        XCTAssertEqual(InsightsMetrics.deltaSpacing, 8)
        XCTAssertEqual(InsightsMetrics.figureCaptionSize, 12)
        XCTAssertEqual(InsightsMetrics.footnoteSize, 12)
    }

    func testTheSessionWindowIsTheMockups() {
        XCTAssertEqual(InsightsMetrics.sessionSpacing, 14)
        XCTAssertEqual(InsightsMetrics.sessionHeaderSpacing, 12)
        XCTAssertEqual(InsightsMetrics.sessionTitleSize, 15)
        XCTAssertEqual(InsightsMetrics.sessionTrailingSize, 12.5)
        XCTAssertEqual(InsightsMetrics.sessionValueSize, 40)
        XCTAssertEqual(InsightsMetrics.sessionValueTracking, -1)
        XCTAssertEqual(InsightsMetrics.sessionValueSpacing, 12)
        XCTAssertEqual(InsightsMetrics.sessionTurnsSize, 13)
        XCTAssertEqual(InsightsMetrics.byProjectSize, 12.5)
        XCTAssertEqual(InsightsMetrics.byProjectTopPadding, 6)
        XCTAssertEqual(
            [InsightsMetrics.projectNameWidth, InsightsMetrics.projectCostWidth, InsightsMetrics.projectTurnsWidth],
            [170, 90, 80]
        )
        XCTAssertEqual(InsightsMetrics.projectColumnGap, 16)
        XCTAssertEqual(InsightsMetrics.projectRowVerticalPadding, 10)
        XCTAssertEqual(InsightsMetrics.projectNameSize, 13)
        XCTAssertEqual(InsightsMetrics.projectCostSize, 13.5)
        XCTAssertEqual(InsightsMetrics.projectTurnsSize, 12)
        XCTAssertEqual(InsightsMetrics.projectBarHeight, 6)
        XCTAssertEqual(InsightsMetrics.projectDividerHeight, 1)
    }

    /// The mockup's 1280 pt window leaves a 974 pt column (1036 less the 30 and 32 pt
    /// gutters): the session window spans 8 of its 12 columns, the cards 4.
    func testTheSessionWindowSpansEightOfTwelveColumns() {
        guard case let .sideBySide(session, cards) = InsightsLayout.topRow(contentWidth: 974) else {
            return XCTFail("side by side expected at 974 pt")
        }
        XCTAssertEqual(session, 642.667, accuracy: 0.001)
        XCTAssertEqual(cards, 311.333, accuracy: 0.001)
        XCTAssertEqual(session + InsightsMetrics.gap + cards, 974, accuracy: 1e-9)
    }

    func testANarrowColumnStacksTheCards() {
        guard case let .sideBySide(session, cards) = InsightsLayout.topRow(contentWidth: 760) else {
            return XCTFail("side by side expected at 760 pt")
        }
        XCTAssertEqual(session, 500, accuracy: 1e-9)
        XCTAssertEqual(cards, 240, accuracy: 1e-9)
        XCTAssertEqual(InsightsLayout.topRow(contentWidth: 759), .stacked)
        // The window's narrowest detail column, less the gutters.
        XCTAssertEqual(
            InsightsLayout.topRow(
                contentWidth: DashboardShellLayout.minimumDetailWidth
                    - DashboardShellLayout.columnLeading - DashboardShellLayout.columnTrailing
            ),
            .stacked
        )
    }
}
