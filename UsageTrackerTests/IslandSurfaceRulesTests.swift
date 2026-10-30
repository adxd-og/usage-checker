import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 (Appearance: the island always dark; glass only on
/// chrome; Reduce Transparency → opaque) and § 5 (P2: Reduce Transparency): what sits under
/// the content.
final class IslandSurfaceRulesTests: XCTestCase {
    func testTheIslandIsOpaqueBlackWhateverTheSetting() {
        XCTAssertEqual(IslandSurfaceRules.backing(kind: .island, reduceTransparency: false), .black)
        XCTAssertEqual(IslandSurfaceRules.backing(kind: .island, reduceTransparency: true), .black)
    }

    func testThePanelGetsAnOpaqueBackingOnlyUnderReduceTransparency() {
        XCTAssertEqual(IslandSurfaceRules.backing(kind: .panel, reduceTransparency: false), .contentsOwn)
        XCTAssertEqual(IslandSurfaceRules.backing(kind: .panel, reduceTransparency: true), .windowBackground)
    }

    /// § 3.1, Surfaces on the island (owner 2026-10-30).
    func testOnlyTheIslandsTilesAndCardsWearTheIslandsSurfaces() {
        XCTAssertTrue(IslandSurfaceRules.surfacesOnIsland(kind: .island))
        XCTAssertFalse(IslandSurfaceRules.surfacesOnIsland(kind: .panel), "the panel keeps its cards")
    }
}
