import XCTest
@testable import Omelette

/// Verification of the island's one path against notch-island spec 2026-10-29 § 3.1 (Clicks
/// through the transparent part; Dismissal): hit regions at the shape's edges and at the
/// notch strip's edges, the three widths, and a click taken from global screen coordinates
/// on a display with a negative, raised origin, the way `IslandController` takes it.
final class IslandGeometryVerificationTests: XCTestCase {
    private let content = CGSize(width: 360, height: 700)

    private func island(on screen: IslandScreen = ScreenFixture.builtIn) -> (IslandGeometry, IslandDisplayResolver.Placement) {
        let placement = IslandDisplayResolver.placement(
            on: screen, entry: .notch(displayID: screen.id), statusItemFrame: nil, panelWidth: 360, menuBarHeight: 32
        )
        return (IslandGeometry(placement: placement, appliedFrame: placement.windowFrame), placement)
    }

    // MARK: The notch strip's edges

    func testTheNotchStripEndsWhereTheContentStarts() {
        let (g, _) = island()
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 31.5), contentSize: content), .notchStrip)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 32), contentSize: content), .body, "under the camera housing")
    }

    func testTheNotchStripCoversTheNotchAndNotAPixelBesideIt() {
        let (g, _) = island()
        // The notch in the window is x 239.5 ..< 424.5.
        XCTAssertEqual(g.region(of: CGPoint(x: 239.5, y: 10), contentSize: content), .notchStrip)
        XCTAssertEqual(g.region(of: CGPoint(x: 424.25, y: 10), contentSize: content), .notchStrip)
        XCTAssertEqual(g.region(of: CGPoint(x: 239.25, y: 10), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 424.75, y: 10), contentSize: content), .body)
    }

    func testThePanelNeverHasANotchStrip() {
        let placement = IslandDisplayResolver.placement(
            on: ScreenFixture.externalRightMenuBarHidden, entry: .statusItem(buttonFrame: CGRect(x: 3800, y: 1416, width: 36, height: 24)),
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        )
        let g = IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
        for x in stride(from: CGFloat(20), to: 370, by: 25) {
            XCTAssertNotEqual(g.region(of: CGPoint(x: x, y: 5), contentSize: content), .notchStrip)
        }
    }

    // MARK: The shape's edges

    func testTheTopEdgeBesideTheNotchIsStillTheIslandNotTheMenuBarBehindIt() {
        // The pointer can rest on the screen's very top row: window y 0.
        let (g, _) = island()
        XCTAssertEqual(g.region(of: CGPoint(x: 100, y: 0), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 560, y: 0), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 0), contentSize: content), .notchStrip)
    }

    func testBothBottomCornersAreRoundedAndBothSidesAreSquareAboveThem() {
        let (g, _) = island()
        // Body x 12 ..< 652, y 0 ..< 746, radius 24.
        XCTAssertEqual(g.region(of: CGPoint(x: 13, y: 745), contentSize: content), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 651, y: 745), contentSize: content), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 13, y: 700), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 651, y: 700), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 651, y: 1), contentSize: content), .body, "top right corner is square")
        XCTAssertEqual(g.region(of: CGPoint(x: 40, y: 745), contentSize: content), .body, "past the radius the bottom edge is straight")
        XCTAssertEqual(g.region(of: CGPoint(x: 624, y: 745), contentSize: content), .body)
    }

    func testThePointJustPastEachSideAndTheBottomIsTheTransparentRest() {
        let (g, _) = island()
        XCTAssertEqual(g.region(of: CGPoint(x: 11, y: 300), contentSize: content), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 653, y: 300), contentSize: content), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 747), contentSize: content), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 745), contentSize: content), .body)
    }

    func testTheBodyIsAsWideAsThePresentationSaysAt560And720() {
        let narrowScreen = IslandScreen(
            id: 9, frame: CGRect(x: 0, y: 0, width: 1419, height: 900), visibleFrame: CGRect(x: 0, y: 70, width: 1419, height: 800),
            safeAreaTop: 32, auxiliaryLeftWidth: 617, auxiliaryRightWidth: 617
        )
        let wideScreen = IslandScreen(
            id: 9, frame: CGRect(x: 0, y: 0, width: 1700, height: 900), visibleFrame: CGRect(x: 0, y: 70, width: 1700, height: 800),
            safeAreaTop: 32, auxiliaryLeftWidth: 757.5, auxiliaryRightWidth: 757.5
        )
        for (screen, bodyWidth) in [(narrowScreen, CGFloat(560)), (wideScreen, CGFloat(720))] {
            let (g, _) = island(on: screen)
            let left = g.bodyRect(contentSize: content).minX
            XCTAssertEqual(left, 12)
            XCTAssertEqual(g.bodyRect(contentSize: content).width, bodyWidth)
            XCTAssertEqual(g.region(of: CGPoint(x: left + bodyWidth - 1, y: 300), contentSize: content), .body, "\(bodyWidth)")
            XCTAssertEqual(g.region(of: CGPoint(x: left + bodyWidth + 1, y: 300), contentSize: content), .outside, "\(bodyWidth)")
        }
    }

    // MARK: A click taken from global coordinates

    func testAClickInGlobalCoordinatesLandsRightOnANegativeOriginRaisedDisplay() {
        let screen = IslandScreen(
            id: 7,
            frame: CGRect(x: -1512, y: 200, width: 1512, height: 982),
            visibleFrame: CGRect(x: -1512, y: 278, width: 1512, height: 872),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        let (g, placement) = island(on: screen)
        XCTAssertEqual(placement.windowFrame, CGRect(x: -1088, y: 286, width: 664, height: 896))
        func region(_ x: CGFloat, _ y: CGFloat) -> IslandGeometry.Region {
            g.region(
                of: IslandGeometry.windowPoint(screenPoint: CGPoint(x: x, y: y), windowFrame: placement.windowFrame),
                contentSize: content
            )
        }
        XCTAssertEqual(region(-756, 1166), .notchStrip, "the middle of the notch")
        XCTAssertEqual(region(-860, 1166), .body, "the menu bar strip left of the camera, still the island")
        XCTAssertEqual(region(-756, 1100), .body, "under the notch, in the content")
        XCTAssertEqual(region(-756, 286 + 10), .outside, "below the island's body, above the Dock")
        XCTAssertEqual(region(-1100, 1000), .outside, "left of the window")
    }

    // MARK: The resting notch

    func testTheRestingNotchIsSquareAtTheTopAndRoundedAtTheBottomOnBothSides() {
        let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let frame = IslandDisplayResolver.restingFrame(notch: notch)
        let path = IslandGeometry.restingPath(notch: notch, appliedFrame: frame)
        XCTAssertTrue(path.contains(CGPoint(x: 0.75, y: 0.5)), "top left is square")
        XCTAssertTrue(path.contains(CGPoint(x: 185.25, y: 0.5)), "top right is square")
        XCTAssertFalse(path.contains(CGPoint(x: 0.75, y: 31.5)), "bottom left is rounded")
        XCTAssertFalse(path.contains(CGPoint(x: 185.25, y: 31.5)), "bottom right is rounded")
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 31.5)), "the bottom edge is straight past the radius")
    }
}
