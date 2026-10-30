import SwiftUI
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

    // MARK: - On the island (notch-island spec 2026-10-29 § 3.1, owner 2026-10-30)

    func testOnTheIslandSurfacesAreNearlyTransparentWithAHairlineEdge() {
        XCTAssertEqual(
            OMPopoverSurface.style(onIsland: true),
            .init(fill: .fixed(.white(0.02)), border: .fixed(.white(0.08)), borderWidth: 0.5)
        )
    }

    func testOffTheIslandSurfacesKeepTheGroupFillAndItsOnePointEdge() {
        XCTAssertEqual(
            OMPopoverSurface.style(onIsland: false),
            .init(fill: .token(.groupFill), border: .token(.groupBorder), borderWidth: 1)
        )
    }

    func testAViewOutsideTheIslandIsNotOnTheIsland() {
        // The Dashboard, Settings and the floating window never set it: they keep today's surfaces.
        XCTAssertFalse(EnvironmentValues().popoverSurfaceOnIsland)
    }
}
