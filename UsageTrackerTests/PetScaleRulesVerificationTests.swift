import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 Rendering and § 3.9 `PetScaleRules`: the
/// largest whole number of device pixels per bead that fits, a bead of at most 1.5 pt, the
/// sprite inside its box, never fewer than one pixel; the origin on the device-pixel grid.
/// Checked against the rule itself over a sweep of displays, bead counts and boxes, not
/// against a handful of picked numbers.
final class PetScaleRulesVerificationTests: XCTestCase {
    private let backings: [CGFloat] = [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3, 4]

    func testThePixelsPerBeadAreTheMostThatKeepABeadWithin1Point5AndTheSpriteInsideTheBox() {
        let boxes: [CGSize] = [
            CGSize(width: 150, height: 300), CGSize(width: 52.5, height: 52.5), CGSize(width: 70, height: 70),
            CGSize(width: 34, height: 32), CGSize(width: 36, height: 300), CGSize(width: 300, height: 17.5),
            CGSize(width: 24, height: 24), CGSize(width: 105, height: 105),
        ]
        for backing in backings {
            for beads in [16, 35] {
                for box in boxes {
                    let scale = PetScaleRules.scale(beads: beads, fitting: box, backingScale: backing)
                    let px = CGFloat(scale.pixelsPerBead)
                    let label = "\(beads) beads in \(box) at \(backing)x -> \(scale.pixelsPerBead)"
                    XCTAssertGreaterThanOrEqual(scale.pixelsPerBead, 1, label)
                    XCTAssertEqual(scale.backingScale, backing, label)
                    func fits(_ pixels: CGFloat) -> Bool {
                        pixels / backing <= 1.5 + 1e-9 && pixels * CGFloat(beads) / backing <= min(box.width, box.height) + 1e-9
                    }
                    if scale.pixelsPerBead > 1 { XCTAssertTrue(fits(px), "too big: \(label)") }
                    XCTAssertFalse(fits(px + 1), "not the largest: \(label)")
                    let side = scale.points(beads: beads) * backing
                    XCTAssertEqual(side, side.rounded(), accuracy: 1e-9, "whole device pixels: \(label)")
                }
            }
        }
    }

    func testTheNamedCasesOfTheSpec() {
        let habitat = CGSize(width: 150, height: 300)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 2).points(beads: 35), 52.5)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 1).points(beads: 35), 35)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 1.5).pixelsPerBead, 2)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 2.5).pixelsPerBead, 3)
        XCTAssertEqual(PetScaleRules.scale(beads: 16, fitting: CGSize(width: 34, height: 32), backingScale: 2).points(beads: 16), 24)
        XCTAssertEqual(PetScaleRules.scale(beads: 16, fitting: CGSize(width: 34, height: 32), backingScale: 3).pixelsPerBead, 4)
    }

    /// A box only one side of which is not measured yet is still a box that is not a finite
    /// number on that side: the answer must not depend on which side it is (width then height
    /// is how `min` happens to order a NaN).
    func testAHalfMeasuredBoxIsTreatedTheSameWhicheverSideIsMissing() {
        let widthMissing = PetScaleRules.scale(beads: 35, fitting: CGSize(width: CGFloat.nan, height: 20), backingScale: 2)
        let heightMissing = PetScaleRules.scale(beads: 35, fitting: CGSize(width: 20, height: CGFloat.nan), backingScale: 2)
        XCTAssertEqual(widthMissing.pixelsPerBead, heightMissing.pixelsPerBead)
    }

    func testABoxWithOneInfiniteSideIsLimitedByTheOther() {
        let wide = PetScaleRules.scale(beads: 35, fitting: CGSize(width: CGFloat.infinity, height: 40), backingScale: 2)
        let tall = PetScaleRules.scale(beads: 35, fitting: CGSize(width: 40, height: CGFloat.infinity), backingScale: 2)
        XCTAssertEqual(wide.pixelsPerBead, 2)
        XCTAssertEqual(tall.pixelsPerBead, 2)
    }

    func testTheOriginSnapsOntoTheDevicePixelGridAtEveryScaleAndNeverMovesMoreThanHalfAPixel() {
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10.3, y: 7.76), CGPoint(x: -3.3, y: 91.49), CGPoint(x: 0.25, y: -0.25),
            CGPoint(x: 1234.567, y: 0.001),
        ]
        for backing in backings {
            for point in points {
                let snapped = PetScaleRules.snapped(point, backingScale: backing)
                XCTAssertEqual(snapped.x * backing, (snapped.x * backing).rounded(), accuracy: 1e-9, "\(point) at \(backing)")
                XCTAssertEqual(snapped.y * backing, (snapped.y * backing).rounded(), accuracy: 1e-9, "\(point) at \(backing)")
                XCTAssertLessThanOrEqual(abs(snapped.x - point.x), 0.5 / backing + 1e-9)
                XCTAssertLessThanOrEqual(abs(snapped.y - point.y), 0.5 / backing + 1e-9)
                XCTAssertEqual(PetScaleRules.snapped(snapped, backingScale: backing), snapped, "snapping twice moves nothing")
            }
        }
    }

    func testAWholeBeadStepFromASnappedOriginStaysOnTheGridAtEveryScale() {
        for backing in backings {
            let scale = PetScaleRules.scale(beads: 35, fitting: CGSize(width: 150, height: 300), backingScale: backing)
            let origin = PetScaleRules.snapped(CGPoint(x: 41.37, y: 12.21), backingScale: backing)
            for beads in -4...9 {
                let x = origin.x + scale.points(beads: beads)
                XCTAssertEqual(x * backing, (x * backing).rounded(), accuracy: 1e-9, "\(beads) beads at \(backing)")
            }
        }
    }

    func testAnUnusableBackingScaleSnapsLikeOne() {
        for backing in [0, -2, CGFloat.nan, .infinity] {
            XCTAssertEqual(PetScaleRules.snapped(CGPoint(x: 2.6, y: 3.4), backingScale: backing), CGPoint(x: 3, y: 3), "\(backing)")
            XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: .zero, backingScale: backing).backingScale, 1, "\(backing)")
        }
    }
}
