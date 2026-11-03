import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 (the strip beside the camera) with spec 2026-11-03: every
/// control in the strip — "‹ All" and the provider logos — fits the row it stands in with a point
/// above and below, and keeps its own height where the row has room for it.
final class IslandStripRulesTests: XCTestCase {
    /// "‹ All" as `PopoverView.stripRow` sizes it: the small capsule's own height, fitted to the row.
    private func backButton(rowHeight: CGFloat) -> CGFloat {
        IslandStripRules.controlHeight(native: OMButtonRules.height(.small), rowHeight: rowHeight)
    }

    func testInAnExternals24PointStripAllAndTheLogosAre22() {
        let strip = IslandLayout(on: ScreenFixture.externalRight, petOn: true).stripHeight
        XCTAssertEqual(strip, 24)
        XCTAssertEqual(backButton(rowHeight: strip), 22)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: strip), 22)
    }

    func testInTheMacBooks32PointStripAllKeeps28AndTheLogos26() {
        let strip = IslandLayout(on: ScreenFixture.builtIn, petOn: true).stripHeight
        XCTAssertEqual(strip, 32)
        XCTAssertEqual(backButton(rowHeight: strip), 28)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: strip), 26)
    }
}
