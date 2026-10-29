import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 (The panel; Clicks through the transparent part;
/// Dismissal): one path is drawn and hit-tested; geometry comes from the frame AppKit
/// applied (P0: origins snap to whole points); the open island's notch strip is where a
/// click closes it; the panel is the content's rounded rectangle.
final class IslandGeometryTests: XCTestCase {
    private let content = CGSize(width: 360, height: 700)

    private func island(applied: CGRect? = nil) -> IslandGeometry {
        let placement = IslandDisplayResolver.placement(
            on: ScreenFixture.builtIn, entry: .notch, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 32
        )
        return IslandGeometry(placement: placement, appliedFrame: applied ?? placement.windowFrame)
    }

    private func panel(button: CGRect = CGRect(x: 3800, y: 1416, width: 36, height: 24)) -> IslandGeometry {
        let placement = IslandDisplayResolver.placement(
            on: ScreenFixture.externalRight, entry: .statusItem(buttonFrame: button),
            statusItemFrame: button, panelWidth: 360, menuBarHeight: 24
        )
        return IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
    }

    func testTheNotchSitsInTheWindowWhereTheScreenHasIt() {
        let g = island()
        XCTAssertEqual(g.windowSize, CGSize(width: 664, height: 896))
        XCTAssertEqual(g.anchorMidX, 332)
        XCTAssertEqual(g.notch, CGRect(x: 239.5, y: 0, width: 185, height: 32))
        XCTAssertEqual(g.stripHeight, 32)
    }

    func testGeometryComesFromTheFrameAppKitApplied() {
        // AppKit put the window one point left of the request: the notch is one point
        // further right inside it.
        let g = island(applied: CGRect(x: 423, y: 86, width: 664, height: 896))
        XCTAssertEqual(g.anchorMidX, 333)
        XCTAssertEqual(g.notch?.minX, 240.5)
    }

    func testTheIslandHangsFromTheTopAtItsFullWidthAroundTheContent() {
        XCTAssertEqual(island().bodyRect(contentSize: content), CGRect(x: 12, y: 0, width: 640, height: 746))
    }

    func testTheContentSitsCentredUnderTheNotchStrip() {
        XCTAssertEqual(island().contentOrigin(contentSize: content), CGPoint(x: 152, y: 32))
    }

    func testAClickOnTheNotchIsTheNotchStrip() {
        XCTAssertEqual(island().region(of: CGPoint(x: 332, y: 16), contentSize: content), .notchStrip)
    }

    func testTheIslandsBodyIsInsideAndItsTransparentRestIsNot() {
        let g = island()
        XCTAssertEqual(g.region(of: CGPoint(x: 100, y: 16), contentSize: content), .body, "the strip beside the camera")
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 740), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 760), contentSize: content), .outside, "below the body")
        XCTAssertEqual(g.region(of: CGPoint(x: 6, y: 100), contentSize: content), .outside, "the side margin")
        XCTAssertEqual(g.region(of: CGPoint(x: 13, y: 745), contentSize: content), .outside, "the rounded bottom corner")
        XCTAssertEqual(g.region(of: CGPoint(x: 13, y: 1), contentSize: content), .body, "the top corners are square")
    }

    func testTheBodyFollowsTheContentsHeight() {
        let g = island()
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 500), contentSize: CGSize(width: 360, height: 400)), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 500), contentSize: content), .body)
    }

    func testThePanelIsTheContentsRoundedRectangle() {
        let g = panel()
        XCTAssertNil(g.notch)
        XCTAssertEqual(g.bodyRect(contentSize: content), CGRect(x: 12, y: 0, width: 360, height: 700))
        XCTAssertEqual(g.contentOrigin(contentSize: content), CGPoint(x: 12, y: 0))
        XCTAssertEqual(g.region(of: CGPoint(x: 192, y: 10), contentSize: content), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 13, y: 1), contentSize: content), .outside, "the rounded top corner")
        XCTAssertEqual(g.region(of: CGPoint(x: 192, y: 705), contentSize: content), .outside)
    }

    func testAClampedPanelKeepsItsBodyInsideTheWindow() {
        let g = panel(button: CGRect(x: 4040, y: 1416, width: 30, height: 24))
        XCTAssertEqual(g.bodyRect(contentSize: content).minX, 12)
    }

    func testAScreenPointBecomesAWindowPointFromTheTopLeft() {
        XCTAssertEqual(
            IslandGeometry.windowPoint(
                screenPoint: CGPoint(x: 500, y: 950),
                windowFrame: CGRect(x: 424, y: 86, width: 664, height: 896)
            ),
            CGPoint(x: 76, y: 32)
        )
    }

    func testTheRestingNotchIsDrawnOverTheNotchInsideItsRoundedOutFrame() {
        let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let frame = IslandDisplayResolver.restingFrame(notch: notch)
        XCTAssertEqual(IslandGeometry.local(notch, in: frame), CGRect(x: 0.5, y: 0, width: 185, height: 32))
        let path = IslandGeometry.restingPath(notch: notch, appliedFrame: frame)
        XCTAssertTrue(path.contains(CGPoint(x: 93, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: 0.25, y: 16)), "the half point the frame rounded out")
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 31.5)), "the rounded bottom corner")
    }
}
