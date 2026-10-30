import SwiftUI
import XCTest
@testable import Omelette

/// Second-pass verification of `IslandGeometry` against notch-island spec 2026-10-29 § 3.2 and
/// plan M2: at progress 0 the shape is the resting notch exactly, so its bottom corners are
/// the resting notch's 8 pt and grow to the open island's 24 pt; a 24 pt corner at the notch
/// would shave the notch's bottom and show a seam where the resting panel hands over.
final class IslandShapeVerification2Tests: XCTestCase {
    private let content = CGSize(width: 360, height: 700)

    private let placement = IslandDisplayResolver.placement(
        on: ScreenFixture.builtIn, entry: .notch, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 32
    )

    private func island() -> IslandGeometry {
        IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
    }

    func testAtTheNotchTheBottomCornersAreTheRestingNotchsEightPointsNotTheOpenIslandsTwentyFour() {
        let g = island()
        let notch = try! XCTUnwrap(g.notch)
        // 4.5 pt in from both edges of each bottom corner: inside an 8 pt corner, cut off by a 24 pt one.
        let left = CGPoint(x: notch.minX + 4.5, y: notch.maxY - 4.5)
        let right = CGPoint(x: notch.maxX - 4.5, y: notch.maxY - 4.5)
        XCTAssertEqual(g.region(of: left, contentSize: content, progress: 0), .notchStrip)
        XCTAssertEqual(g.region(of: right, contentSize: content, progress: 0), .notchStrip)
        let resting = IslandGeometry.restingPath(notch: try! XCTUnwrap(placement.notch), appliedFrame: placement.windowFrame)
        XCTAssertEqual(resting.contains(left), g.path(contentSize: content, progress: 0).contains(left), "the hand-off shows no seam")
        XCTAssertEqual(resting.contains(right), g.path(contentSize: content, progress: 0).contains(right))
    }

    func testTheBottomCornersGrowRoundedAsTheShapeGrowsAndAreTwentyFourWhenOpen() {
        let g = island()
        let open = g.bodyRect(contentSize: content)
        let corner = CGPoint(x: open.minX + 4.5, y: open.maxY - 4.5)
        XCTAssertFalse(g.path(contentSize: content, progress: 1).contains(corner), "a 24 pt corner cuts it off")
        // Between the two the corner is between them: the same relative point at 3/4 progress is
        // cut off by the 20 pt corner as well.
        let body = g.shapeRect(contentSize: content, progress: 0.75)
        XCTAssertFalse(g.path(contentSize: content, progress: 0.75).contains(CGPoint(x: body.minX + 4.5, y: body.maxY - 4.5)))
    }
}
