import SwiftUI
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 Notch hint, § 3.6: the resting window is the notch and the ears
/// shown, rounded out to whole points, and takes the hint's room only while the hint shows. Everything
/// drawn is one black shape: only there does the window server hand the panel a click.
final class RestingLayoutTests: XCTestCase {
    /// This 14-inch's notch (`ScreenFixture.builtIn`).
    private let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)

    private func layout(left: Bool = false, right: Bool = false) -> RestingLayout {
        let frame = RestingLayout.frame(notch: notch, left: left, right: right, hintRoom: false)
        return RestingLayout(notch: notch, left: left, right: right, appliedFrame: frame)
    }

    func testAtRestTheWindowIsTheNotchRoundedOut() {
        XCTAssertEqual(
            RestingLayout.frame(notch: notch, left: false, right: false, hintRoom: false),
            IslandDisplayResolver.restingFrame(notch: notch)
        )
    }

    func testEachEarWidensItsOwnSideOnly() {
        XCTAssertEqual(
            RestingLayout.frame(notch: notch, left: true, right: false, hintRoom: false),
            CGRect(x: 629, y: 950, width: 220, height: 32)
        )
        XCTAssertEqual(
            RestingLayout.frame(notch: notch, left: false, right: true, hintRoom: false),
            CGRect(x: 663, y: 950, width: 220, height: 32)
        )
        XCTAssertEqual(
            RestingLayout.frame(notch: notch, left: true, right: true, hintRoom: false),
            CGRect(x: 629, y: 950, width: 254, height: 32)
        )
    }

    func testTheHintTakesRoomBesideAndBelowOnlyWhenAsked() {
        XCTAssertEqual(
            RestingLayout.frame(notch: notch, left: false, right: false, hintRoom: true),
            CGRect(x: 657, y: 942, width: 198, height: 40)
        )
    }

    func testEarsAreAsTallAsTheNotchAnd34Wide() throws {
        let both = layout(left: true, right: true)
        XCTAssertEqual(both.notch, CGRect(x: 34.5, y: 0, width: 185, height: 32))
        XCTAssertEqual(both.leftEar, CGRect(x: 0.5, y: 0, width: 34, height: 32))
        XCTAssertEqual(both.rightEar, CGRect(x: 219.5, y: 0, width: 34, height: 32))
        XCTAssertNil(layout().leftEar)
        XCTAssertNil(layout().rightEar)
    }

    func testTheShapeHoldsTheNotchAndTheEarsShownAndNothingBeyond() throws {
        let both = layout(left: true, right: false)
        let shape = both.shape()
        let ear = try XCTUnwrap(both.leftEar)
        XCTAssertTrue(shape.contains(CGPoint(x: both.notch.midX, y: both.notch.midY)))
        XCTAssertTrue(shape.contains(CGPoint(x: ear.midX, y: ear.midY)))
        XCTAssertFalse(shape.contains(CGPoint(x: both.notch.maxX + 2, y: both.notch.midY)), "no ear on that side")
        XCTAssertFalse(shape.contains(CGPoint(x: both.notch.midX, y: both.notch.maxY + 1)), "nothing under the notch at rest")
    }

    /// The notch's corner is rounded: an ear beside it fills the wedge.
    func testNoWedgeShowsBetweenAnEarAndTheNotch() {
        let wedge = CGPoint(x: layout().notch.minX + 1, y: layout().notch.maxY - 1)
        XCTAssertFalse(layout().shape().contains(wedge))
        let attached = layout(left: true)
        XCTAssertTrue(attached.shape().contains(CGPoint(x: attached.notch.minX + 1, y: attached.notch.maxY - 1)))
    }

    func testTheBreathGrowsTheNotchAndLeavesTheEarsAlone() throws {
        let both = layout(left: true, right: true)
        let look = NotchHint.Look(down: 5, widen: 3, outlined: false)
        let shape = both.shape(look)
        XCTAssertTrue(shape.contains(CGPoint(x: both.notch.midX, y: both.notch.maxY + 4)))
        let ear = try XCTUnwrap(both.leftEar)
        XCTAssertFalse(shape.contains(CGPoint(x: ear.midX, y: ear.maxY + 1)), "the ear keeps the notch's height")
    }

    func testTheOutlineSitsJustOutsideTheNotch() {
        let rest = layout()
        let bounds = rest.outline().boundingRect
        XCTAssertEqual(bounds.minX, rest.notch.minX - 1, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, rest.notch.maxX + 1, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, rest.notch.maxY + 1, accuracy: 0.01)
    }

    func testTheTrackedAreaIsTheNotchAndWhileUpTheGrownShape() {
        let rest = layout(left: true)
        XCTAssertEqual(rest.trackedRect(hintUp: false), rest.notch, "an ear is not the notch (plan R10)")
        XCTAssertEqual(
            rest.trackedRect(hintUp: true),
            CGRect(x: rest.notch.minX - 3, y: rest.notch.minY, width: rest.notch.width + 6, height: rest.notch.height + 5)
        )
    }
}
