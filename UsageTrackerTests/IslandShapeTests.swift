import SwiftUI
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.2 (Open: the shape from the notch rect to the open rect,
/// concave top shoulders, bottom radius 24) and § 3.1 (one path drawn and hit-tested): the
/// island's shape at every progress of its motion, the open spring's overshoot kept inside
/// the window, the notch strip only where the shape is drawn, and the panel's shape, which
/// does not move.
final class IslandShapeTests: XCTestCase {
    private let content = CGSize(width: 360, height: 700)

    /// On the 14-inch: window 664 x 896, notch x 239.5 ..< 424.5, y 0 ..< 32, open body
    /// x 12 ..< 652, y 0 ..< 746.
    private func island(on screen: IslandScreen = ScreenFixture.builtIn) -> IslandGeometry {
        let placement = IslandDisplayResolver.placement(
            on: screen, entry: .notch, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 32
        )
        return IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
    }

    /// The open spring's highest point, from SwiftUI's own curve (≈ 1.0111).
    private var openPeak: Double {
        stride(from: 0.0, through: 1.5, by: 0.001)
            .map { IslandMotion.open.value(target: 1.0, time: $0) }
            .max() ?? 1
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 0.001, file: file, line: line)
    }

    func testAtProgressZeroTheShapeIsTheNotchWithTheRestingCorners() {
        let g = island()
        let notch = CGRect(x: 239.5, y: 0, width: 185, height: 32)
        XCTAssertEqual(g.shapeRect(contentSize: content, progress: 0), notch)
        let path = g.path(contentSize: content, progress: 0)
        assertRect(path.boundingRect, notch)
        XCTAssertTrue(path.contains(CGPoint(x: 332, y: 16)))
        XCTAssertTrue(path.contains(CGPoint(x: 240, y: 0.5)), "square at the top")
        XCTAssertFalse(path.contains(CGPoint(x: 240, y: 31.5)), "rounded at the bottom, as the resting notch")
        XCTAssertFalse(path.contains(CGPoint(x: 238.5, y: 0.5)), "no shoulders at the notch")
    }

    func testAtProgressOneTheShapeIsTheOpenBodyWithConcaveShoulders() {
        let g = island()
        XCTAssertEqual(g.shapeRect(contentSize: content, progress: 1), g.bodyRect(contentSize: content))
        let path = g.path(contentSize: content, progress: 1)
        XCTAssertTrue(path.contains(CGPoint(x: 11, y: 3)), "the left shoulder, beside the body's top")
        XCTAssertTrue(path.contains(CGPoint(x: 653, y: 3)), "the right shoulder")
        XCTAssertFalse(path.contains(CGPoint(x: 11, y: 8)), "the shoulder curves into the side")
        XCTAssertFalse(path.contains(CGPoint(x: 653, y: 8)))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 3)), "it thins to the top edge at its outer end")
        XCTAssertFalse(path.contains(CGPoint(x: 11, y: 300)), "below the shoulders the side is straight")
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 664, accuracy: 0.001)
    }

    func testHalfwayTheShapeIsHalfwayInEveryDimension() {
        let g = island()
        XCTAssertEqual(g.shapeRect(contentSize: content, progress: 0.5), CGRect(x: 125.75, y: 0, width: 412.5, height: 389))
        let path = g.path(contentSize: content, progress: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: 130, y: 200)))
        XCTAssertFalse(path.contains(CGPoint(x: 115, y: 200)), "outside the half-grown body")
        XCTAssertTrue(path.contains(CGPoint(x: 332, y: 380)))
        XCTAssertFalse(path.contains(CGPoint(x: 332, y: 395)))
    }

    func testTheOpenSpringsOvershootStaysInsideTheWindow() {
        let wide = IslandScreen(
            id: 9, frame: CGRect(x: 0, y: 0, width: 1700, height: 900),
            visibleFrame: CGRect(x: 0, y: 70, width: 1700, height: 800),
            safeAreaTop: 32, auxiliaryLeftWidth: 757.5, auxiliaryRightWidth: 757.5
        )
        XCTAssertGreaterThan(openPeak, 1.005, "the open spring does overshoot")
        for screen in [ScreenFixture.builtIn, ScreenFixture.narrowNotched, wide] {
            let g = island(on: screen)
            let peak = g.path(contentSize: content, progress: openPeak).boundingRect
            XCTAssertGreaterThanOrEqual(peak.minX, -0.001, "\(screen.frame.width)")
            XCTAssertLessThanOrEqual(peak.maxX, g.windowSize.width + 0.001, "\(screen.frame.width)")
            XCTAssertLessThanOrEqual(peak.maxY, g.windowSize.height + 0.001, "\(screen.frame.width)")
            XCTAssertGreaterThan(
                g.shapeRect(contentSize: content, progress: openPeak).width,
                g.bodyRect(contentSize: content).width,
                "the body itself still overshoots, \(screen.frame.width)"
            )
        }
    }

    func testABodyTallerThanTheWindowIsKeptInsideIt() {
        let g = island()
        let tall = CGSize(width: 360, height: 900)
        XCTAssertEqual(g.bodyRect(contentSize: tall).maxY, 946, "taller than the 896 pt window")
        XCTAssertEqual(g.shapeRect(contentSize: tall, progress: 1).maxY, 896)
        XCTAssertEqual(g.shapeRect(contentSize: tall, progress: openPeak).maxY, 896)
    }

    func testAClickOutsideTheGrowingShapeGoesThroughEvenWhereTheOpenBodyWillBe() {
        let g = island()
        // At 0.3 the body is x 171.25 ..< 492.75, y 0 ..< 246.2.
        XCTAssertEqual(g.region(of: CGPoint(x: 100, y: 100), contentSize: content, progress: 0.3), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 300), contentSize: content, progress: 0.3), .outside)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 240), contentSize: content, progress: 0.3), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 100, y: 100), contentSize: content, progress: 1), .body)
        XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 300), contentSize: content, progress: 1), .body)
    }

    func testTheNotchStripIsTheNotchAtEveryProgress() {
        let g = island()
        for progress in [0, 0.25, 0.5, 1, openPeak] {
            XCTAssertEqual(g.region(of: CGPoint(x: 332, y: 16), contentSize: content, progress: progress), .notchStrip, "\(progress)")
        }
        XCTAssertEqual(
            g.region(of: CGPoint(x: 240, y: 31.5), contentSize: content, progress: 0), .outside,
            "inside the notch's rect but outside the shape's rounded corner: not drawn, not the strip"
        )
    }

    func testThePanelsShapeDoesNotMove() {
        let button = CGRect(x: 3800, y: 1416, width: 36, height: 24)
        let placement = IslandDisplayResolver.placement(
            on: ScreenFixture.externalRightMenuBarHidden, entry: .statusItem(buttonFrame: button),
            statusItemFrame: button, panelWidth: 360, menuBarHeight: 24
        )
        let g = IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
        XCTAssertEqual(g.path(contentSize: content, progress: 0).description, g.path(contentSize: content).description)
        XCTAssertEqual(g.shapeRect(contentSize: content, progress: 0), g.bodyRect(contentSize: content))
    }

    func testWithoutAProgressTheShapeIsTheOpenOne() {
        let g = island()
        XCTAssertEqual(g.path(contentSize: content).description, g.path(contentSize: content, progress: 1).description)
        XCTAssertEqual(g.region(of: CGPoint(x: 11, y: 3), contentSize: content), .body, "the shoulder counts as the island")
    }
}
