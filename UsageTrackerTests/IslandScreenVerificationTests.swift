import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 2 and § 3.1 for `IslandScreen.notchRect`:
/// a notch needs both menu bar areas beside it, whichever side is the empty one.
final class IslandScreenVerificationTests: XCTestCase {
    private func screen(left: CGFloat?, right: CGFloat?, top: CGFloat = 32) -> IslandScreen {
        IslandScreen(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 872),
            safeAreaTop: top, auxiliaryLeftWidth: left, auxiliaryRightWidth: right
        )
    }

    func testAnEmptyRightAreaMeansNoNotchJustAsAnEmptyLeftOneDoes() {
        XCTAssertNil(screen(left: 663.5, right: 0).notchRect)
        XCTAssertNil(screen(left: 0, right: 663.5).notchRect)
    }

    func testANegativeAreaWidthMeansNoNotch() {
        XCTAssertNil(screen(left: -10, right: 663.5).notchRect)
        XCTAssertNil(screen(left: 663.5, right: -10).notchRect)
    }

    func testANegativeSafeAreaMeansNoNotch() {
        XCTAssertNil(screen(left: 663.5, right: 663.5, top: -1).notchRect)
    }
}
