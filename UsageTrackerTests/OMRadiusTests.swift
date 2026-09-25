import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens, "Radii": popover 24, popover group 16,
/// popover tile 18, dashboard card 22, window 26, sidebar 18, nav item 11, controls
/// capsule. Today's two radii stay until their screens move.
final class OMRadiusTests: XCTestCase {
    func testEachSurfaceHasTheSpecsRadius() {
        XCTAssertEqual(OMRadius.corner(for: .popover), .rounded(24))
        XCTAssertEqual(OMRadius.corner(for: .popoverGroup), .rounded(16))
        XCTAssertEqual(OMRadius.corner(for: .popoverTile), .rounded(18))
        XCTAssertEqual(OMRadius.corner(for: .dashboardCard), .rounded(22))
        XCTAssertEqual(OMRadius.corner(for: .window), .rounded(26))
        XCTAssertEqual(OMRadius.corner(for: .sidebar), .rounded(18))
        XCTAssertEqual(OMRadius.corner(for: .navItem), .rounded(11))
    }

    func testControlsAreCapsules() {
        XCTAssertEqual(OMRadius.corner(for: .control), .capsule)
    }

    func testTodaysTwoRadiiAreUnchanged() {
        XCTAssertEqual(OMRadius.tile, 16)
        XCTAssertEqual(OMRadius.row, 12)
    }

    func testASurfaceShapeIsAContinuousRoundedRectangleOfItsRadius() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
        XCTAssertEqual(
            OMCornerShape(.dashboardCard).path(in: rect),
            Path(roundedRect: rect, cornerRadius: 22, style: .continuous)
        )
    }

    func testAControlShapeIsACapsuleAtAnyHeight() {
        let wide = CGRect(x: 0, y: 0, width: 120, height: 30)
        let tall = CGRect(x: 0, y: 0, width: 40, height: 80)
        XCTAssertEqual(OMCornerShape(.control).path(in: wide), Path(roundedRect: wide, cornerRadius: 15, style: .continuous))
        XCTAssertEqual(OMCornerShape(.control).path(in: tall), Path(roundedRect: tall, cornerRadius: 20, style: .continuous))
    }

    func testAnInsetShrinksTheRadiusWithTheRectLikeRoundedRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
        XCTAssertEqual(
            OMCornerShape(.navItem).inset(by: 2).path(in: rect),
            Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 9, style: .continuous)
        )
    }

    func testAnInsetNeverTurnsTheRadiusNegative() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
        XCTAssertEqual(
            OMCornerShape(.navItem).inset(by: 20).path(in: rect),
            Path(roundedRect: rect.insetBy(dx: 20, dy: 20), cornerRadius: 0, style: .continuous)
        )
    }
}
