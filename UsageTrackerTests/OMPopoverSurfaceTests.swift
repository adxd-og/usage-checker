import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Tokens, radii: "popover group 16, popover tile 18"; §
/// Principles 1: content sits on quiet fills, never glass.
final class OMPopoverSurfaceTests: XCTestCase {
    func testTilesHaveTheEighteenPointCornerAndGroupsTheSixteen() {
        XCTAssertEqual(OMRadius.corner(for: OMPopoverSurface.tile.corner), .rounded(18))
        XCTAssertEqual(OMRadius.corner(for: OMPopoverSurface.group.corner), .rounded(16))
    }

    func testSurfacesWearTheGroupFillAndAOnePointEdge() {
        XCTAssertEqual(OMPopoverSurface.fill, .groupFill)
        XCTAssertEqual(OMPopoverSurface.border, .groupBorder)
        XCTAssertEqual(OMPopoverSurface.borderWidth, 1)
    }
}
