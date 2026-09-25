import XCTest
@testable import Omelette

/// Independent verification of `OverviewLayout` (`Dashboard-Overview(-Light).dc.html`'s
/// twelve-column grid) and the "`OverviewLayout.resolvedWidth` never NaN" rule from the
/// session rulings. Written without reading `OverviewLayoutTests.swift`; checks the exact
/// widths named in the brief (883 / 884 / 1280 / infinity / NaN) directly rather than
/// through the `Layout` protocol.
final class OverviewLayoutVerificationTests: XCTestCase {
    // MARK: - resolvedWidth never NaN

    func testResolvedWidthFallsBackToTheMinimumForNilProposal() {
        XCTAssertEqual(OverviewLayout.resolvedWidth(nil), OverviewLayout.minimumSideBySideWidth)
    }

    func testResolvedWidthFallsBackToTheMinimumForInfinity() {
        let resolved = OverviewLayout.resolvedWidth(.infinity)
        XCTAssertFalse(resolved.isNaN)
        XCTAssertEqual(resolved, OverviewLayout.minimumSideBySideWidth)
    }

    func testResolvedWidthFallsBackToTheMinimumForNaN() {
        let resolved = OverviewLayout.resolvedWidth(.nan)
        XCTAssertFalse(resolved.isNaN, "a NaN proposal must not produce a NaN result")
        XCTAssertEqual(resolved, OverviewLayout.minimumSideBySideWidth)
    }

    func testResolvedWidthPassesThroughAnyFiniteProposal() {
        XCTAssertEqual(OverviewLayout.resolvedWidth(1000), 1000)
        XCTAssertEqual(OverviewLayout.resolvedWidth(0), 0)
    }

    // MARK: - columns() at the exact widths named in the brief

    func testColumnsAt883StacksFullWidth() {
        XCTAssertNil(OverviewLayout.columns(width: 883), "one point short of the minimum must stack")
    }

    func testColumnsAt884SplitsSevenToFiveTwelfths() {
        // shared = 884 - 20 = 864; rings = floor(864 * 7/12) = 504; cli = 864 - 504 = 360.
        let columns = OverviewLayout.columns(width: 884)
        XCTAssertEqual(columns?.rings, 504)
        XCTAssertEqual(columns?.cli, 360)
    }

    func testColumnsAt1280() {
        // shared = 1260; rings = floor(1260 * 7/12) = 735; cli = 1260 - 735 = 525.
        let columns = OverviewLayout.columns(width: 1280)
        XCTAssertEqual(columns?.rings, 735)
        XCTAssertEqual(columns?.cli, 525)
    }

    func testColumnsAtInfinityFallsBackToTheMinimumSideBySideLayout() {
        let atInfinity = OverviewLayout.columns(width: .infinity)
        let atMinimum = OverviewLayout.columns(width: OverviewLayout.minimumSideBySideWidth)
        XCTAssertEqual(atInfinity, atMinimum)
        XCTAssertNotNil(atInfinity)
    }

    func testColumnsAtNaNFallsBackToTheMinimumSideBySideLayoutWithoutCrashing() {
        let atNaN = OverviewLayout.columns(width: .nan)
        let atMinimum = OverviewLayout.columns(width: OverviewLayout.minimumSideBySideWidth)
        XCTAssertEqual(atNaN, atMinimum)
    }

    func testColumnsWidthsAlwaysSumToTheSharedWidth() {
        for width: CGFloat in [884, 920, 1000, 1280, 2000] {
            guard let columns = OverviewLayout.columns(width: width) else { continue }
            XCTAssertEqual(columns.rings + columns.cli, width - OverviewLayout.spacing,
                            "the two cards plus the gap must exactly fill the row at width \(width)")
        }
    }

    // MARK: - Which cards a provider gets

    func testCLICardRequiresACostLog() {
        XCTAssertTrue(OverviewLayout.showsCLICard(hasBreakdown: true))
        XCTAssertFalse(OverviewLayout.showsCLICard(hasBreakdown: false))
    }

    func testTokensCardRequiresACostLogAndSomethingFromToday() {
        XCTAssertFalse(OverviewLayout.showsTokensCard(hasBreakdown: true, todayTokens: 0),
                        "a bar of nothing says less than no card")
        XCTAssertTrue(OverviewLayout.showsTokensCard(hasBreakdown: true, todayTokens: 1))
        XCTAssertFalse(OverviewLayout.showsTokensCard(hasBreakdown: false, todayTokens: 1_000_000),
                        "no cost log means no per-category token split to show")
    }
}
