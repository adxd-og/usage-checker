import XCTest
@testable import Omelette

/// Spec 2026-11-03 § Virtual notch: a display without a notch gets a pill centred on its frame, as
/// tall as its menu bar, as wide as the attached physical notch or 185 pt without one; none where
/// the menu bar is hidden or the display is narrower than 1280 pt.
final class VirtualNotchRulesTests: XCTestCase {
    private func rect(_ screen: IslandScreen, reference: CGFloat? = nil) -> CGRect? {
        VirtualNotchRules.rect(screen: screen, referenceNotchWidth: reference)
    }

    func testTheNumbersAreTheSpecs() {
        XCTAssertEqual(VirtualNotchRules.fallbackWidth, 185)
        XCTAssertEqual(VirtualNotchRules.minimumScreenWidth, 1280)
    }

    func testAnExternalDisplayGetsAPillCentredInItsMenuBar() {
        // 2560 wide from x 1512: centre 2792; the menu bar is 1440 − 1416 = 24 pt.
        XCTAssertEqual(rect(ScreenFixture.externalRight), CGRect(x: 2699.5, y: 1416, width: 185, height: 24))
    }

    func testThePillTakesTheAttachedNotchsWidth() {
        XCTAssertEqual(
            rect(ScreenFixture.externalRight, reference: 192), CGRect(x: 2696, y: 1416, width: 192, height: 24)
        )
        XCTAssertEqual(rect(ScreenFixture.externalRight, reference: 0)?.width, 185, "a width that is no width: the fallback")
    }

    /// Its menu bar is 32 pt, as tall as the camera housing it does not have.
    func testANotchlessDisplayTheSizeOfThe14InchGetsTheNotchsOwnRect() {
        XCTAssertEqual(rect(ScreenFixture.builtIn), CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    func testADisplayLeftOfTheMainOneKeepsItsNegativeX() {
        XCTAssertEqual(rect(ScreenFixture.externalLeft), CGRect(x: -1052.5, y: 1056, width: 185, height: 24))
    }

    func testA1280PointDisplayGetsAPillAndA1279PointOneDoesNot() {
        XCTAssertEqual(rect(ScreenFixture.wide1280), CGRect(x: 2059.5, y: 776, width: 185, height: 24))
        XCTAssertNil(rect(ScreenFixture.narrow1279))
        XCTAssertNil(rect(ScreenFixture.narrow1279, reference: 160), "a narrower pill does not lower the floor")
    }

    func testAHiddenMenuBarMeansNoPill() {
        XCTAssertNil(rect(ScreenFixture.externalRightMenuBarHidden))
        XCTAssertNil(rect(ScreenFixture.externalLeftMenuBarHidden, reference: 185))
    }
}
