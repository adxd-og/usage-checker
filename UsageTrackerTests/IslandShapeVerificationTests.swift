import SwiftUI
import XCTest
@testable import Omelette

/// Verification of `IslandGeometry` at any progress against notch-island spec 2026-10-29 § 3.1
/// (one path for the drawing and the click-through hit test; the window's mouse handling
/// follows the shape) and § 3.2 (the shape from the notch rect to the open rect, concave
/// shoulders), with the plan's M3 (the shape stays inside the window) and M17 (the notch
/// strip is the drawn notch).
final class IslandShapeVerificationTests: XCTestCase {
    private let content = CGSize(width: 360, height: 700)

    private let wide = IslandScreen(
        id: 9, frame: CGRect(x: 0, y: 0, width: 1800, height: 1000),
        visibleFrame: CGRect(x: 0, y: 70, width: 1800, height: 900),
        safeAreaTop: 32, auxiliaryLeftWidth: 807.5, auxiliaryRightWidth: 807.5
    )

    private func island(on screen: IslandScreen) -> IslandGeometry {
        let placement = IslandDisplayResolver.placement(
            on: screen, entry: .notch(displayID: screen.id), statusItemFrame: nil, panelWidth: 360, menuBarHeight: 32
        )
        return IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
    }

    private var screens: [IslandScreen] { [ScreenFixture.builtIn, ScreenFixture.narrowNotched, wide] }

    private var progresses: [Double] {
        [-0.4, -0.01, 0, 0.01, 0.02, 0.05, 0.1, 0.25, 0.4, 0.5, 0.63, 0.75, 0.9, 0.99, 1, 1.005, 1.0111, 1.05]
    }

    /// Window points on a grid with a pitch of 6 pt.
    private func grid(_ g: IslandGeometry) -> [CGPoint] {
        var points: [CGPoint] = []
        var y = 0.5
        while y < g.windowSize.height {
            var x = 0.5
            while x < g.windowSize.width {
                points.append(CGPoint(x: x, y: y))
                x += 6
            }
            y += 6
        }
        return points
    }

    func testAPointIsOutsideExactlyWhereTheDrawnPathDoesNotContainIt() {
        for screen in screens {
            let g = island(on: screen)
            let notch = try! XCTUnwrap(g.notch)
            for progress in progresses {
                let path = g.path(contentSize: content, progress: progress)
                for point in grid(g) + [CGPoint(x: notch.midX, y: notch.midY), CGPoint(x: notch.minX + 0.5, y: notch.maxY - 0.5)] {
                    let region = g.region(of: point, contentSize: content, progress: progress)
                    XCTAssertEqual(region == .outside, !path.contains(point), "\(screen.frame.width) p=\(progress) \(point)")
                    if region == .notchStrip {
                        XCTAssertTrue(notch.contains(point), "a strip point lies in the notch rect, \(point)")
                    }
                    if path.contains(point), !notch.contains(point) {
                        XCTAssertEqual(region, .body, "\(screen.frame.width) p=\(progress) \(point)")
                    }
                }
            }
        }
    }

    func testTheNotchCentreIsTheStripAtEveryProgressAndItsBottomCornersJoinAsSoonAsTheShapeGrows() {
        for screen in screens {
            let g = island(on: screen)
            let notch = try! XCTUnwrap(g.notch)
            for progress in progresses {
                XCTAssertEqual(
                    g.region(of: CGPoint(x: notch.midX, y: notch.midY), contentSize: content, progress: progress),
                    .notchStrip, "\(screen.frame.width) p=\(progress)"
                )
            }
            let corner = CGPoint(x: notch.minX + 0.5, y: notch.maxY - 0.5)
            XCTAssertEqual(g.region(of: corner, contentSize: content, progress: 0), .outside, "rounded off at rest")
            XCTAssertEqual(g.region(of: corner, contentSize: content, progress: -0.4), .outside, "below the notch is the notch")
            for progress in [0.02, 0.05, 0.1, 0.5, 1.0] {
                XCTAssertEqual(
                    g.region(of: corner, contentSize: content, progress: progress), .notchStrip,
                    "\(screen.frame.width) p=\(progress): the grown shape covers the notch's corner"
                )
            }
        }
    }

    func testTheShapeStaysInsideTheWindowAtEveryProgressOnEveryScreen() {
        for screen in screens {
            let g = island(on: screen)
            for progress in progresses {
                let bounds = g.path(contentSize: content, progress: progress).boundingRect
                let tag = "\(screen.frame.width) p=\(progress)"
                XCTAssertGreaterThanOrEqual(bounds.minX, -0.001, tag)
                XCTAssertGreaterThanOrEqual(bounds.minY, -0.001, tag)
                XCTAssertLessThanOrEqual(bounds.maxX, g.windowSize.width + 0.001, tag)
                XCTAssertLessThanOrEqual(bounds.maxY, g.windowSize.height + 0.001, tag)
                let rect = g.shapeRect(contentSize: content, progress: progress)
                XCTAssertGreaterThanOrEqual(rect.width, 0, tag)
                XCTAssertGreaterThanOrEqual(rect.height, 0, tag)
                XCTAssertEqual(rect.minY, 0, "the shape hangs from the top edge, " + tag)
            }
        }
    }

    func testTheShapeGrowsMonotonicallyFromTheNotchToTheOpenBody() {
        for screen in screens {
            let g = island(on: screen)
            let notch = try! XCTUnwrap(g.notch)
            let open = g.bodyRect(contentSize: content)
            var last = g.shapeRect(contentSize: content, progress: 0)
            var lastBounds = g.path(contentSize: content, progress: 0).boundingRect
            XCTAssertEqual(last.minX, notch.minX, accuracy: 0.001)
            XCTAssertEqual(last.maxX, notch.maxX, accuracy: 0.001)
            XCTAssertEqual(last.maxY, notch.maxY, accuracy: 0.001)
            for step in 1...100 {
                let progress = Double(step) / 100
                let rect = g.shapeRect(contentSize: content, progress: progress)
                let bounds = g.path(contentSize: content, progress: progress).boundingRect
                XCTAssertLessThanOrEqual(rect.minX, last.minX + 1e-9, "x \(progress)")
                XCTAssertGreaterThanOrEqual(rect.maxX, last.maxX - 1e-9, "x \(progress)")
                XCTAssertGreaterThanOrEqual(rect.maxY, last.maxY - 1e-9, "y \(progress)")
                XCTAssertGreaterThanOrEqual(bounds.width, lastBounds.width - 1e-9, "path \(progress)")
                XCTAssertGreaterThanOrEqual(bounds.height, lastBounds.height - 1e-9, "path \(progress)")
                last = rect
                lastBounds = bounds
            }
            XCTAssertEqual(last, open)
        }
    }

    func testBelowTheNotchTheShapeIsTheNotchAndAboveOneTheShouldersStopGrowing() {
        let g = island(on: ScreenFixture.builtIn)
        XCTAssertEqual(
            g.shapeRect(contentSize: content, progress: -0.4), g.shapeRect(contentSize: content, progress: 0),
            "a critically damped close that undershoots draws the notch, not less"
        )
        XCTAssertEqual(
            g.path(contentSize: content, progress: -0.4).description, g.path(contentSize: content, progress: 0).description
        )
        // Past 1 the body overshoots; the shoulders and the corners are the open ones.
        let open = g.path(contentSize: content, progress: 1)
        XCTAssertTrue(open.contains(CGPoint(x: 11, y: 3)))
        let side = g.shapeRect(contentSize: content, progress: 1.0111).minX
        let over = g.path(contentSize: content, progress: 1.0111)
        XCTAssertTrue(over.contains(CGPoint(x: side - 1, y: 3)), "the shoulder is still there past 1")
        XCTAssertFalse(over.contains(CGPoint(x: side - 1, y: 8)), "and no taller: 12 pt at most")
        XCTAssertFalse(over.contains(CGPoint(x: side - 13, y: 0.5)), "and no wider")
    }

    func testTheShouldersAppearWithTheShapeAndAreSmallerWhileItIsSmall() {
        let g = island(on: ScreenFixture.builtIn)
        // At p = 0.5 the body is x 125.75 ..< 538.25 and its shoulder 6 pt.
        let half = g.path(contentSize: content, progress: 0.5)
        XCTAssertTrue(half.contains(CGPoint(x: 124, y: 1)), "the shoulder, beside the half-grown body")
        XCTAssertFalse(half.contains(CGPoint(x: 124, y: 9)), "6 pt tall, not 12")
        XCTAssertFalse(half.contains(CGPoint(x: 118, y: 1)), "6 pt wide, not 12")
        let rest = g.path(contentSize: content, progress: 0)
        XCTAssertFalse(rest.contains(CGPoint(x: 238.9, y: 1)), "none at the notch")
    }

    func testThePanelHasNoMotionAtAnyProgress() {
        let button = CGRect(x: 3800, y: 1416, width: 36, height: 24)
        let placement = IslandDisplayResolver.placement(
            on: ScreenFixture.externalRightMenuBarHidden, entry: .statusItem(buttonFrame: button),
            statusItemFrame: button, panelWidth: 360, menuBarHeight: 24
        )
        let g = IslandGeometry(placement: placement, appliedFrame: placement.windowFrame)
        let reference = g.path(contentSize: content, progress: 1)
        for progress in progresses {
            XCTAssertEqual(g.path(contentSize: content, progress: progress).description, reference.description, "\(progress)")
            for point in [CGPoint(x: 100, y: 100), CGPoint(x: 5, y: 5), CGPoint(x: 200, y: 690), CGPoint(x: 200, y: 900)] {
                XCTAssertEqual(
                    g.region(of: point, contentSize: content, progress: progress),
                    g.region(of: point, contentSize: content, progress: 1), "\(progress) \(point)"
                )
                XCTAssertNotEqual(g.region(of: point, contentSize: content, progress: progress), .notchStrip)
            }
        }
    }
}
