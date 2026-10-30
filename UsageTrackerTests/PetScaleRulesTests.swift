import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering and § 3.9 `PetScaleRules`: the largest whole
/// number of device pixels per bead that fits (3 at 2×, giving 52.5 pt; 2 at 1× would give
/// 70 pt, so 1 px at 35 pt), the origin snapped to the device-pixel grid, animation offsets
/// in whole beads only.
final class PetScaleRulesTests: XCTestCase {
    private let habitat = CGSize(width: 150, height: 300)

    func testOnRetinaABeadIsThreeDevicePixelsAndThePet52Point5Points() {
        let scale = PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 2)
        XCTAssertEqual(scale.pixelsPerBead, 3)
        XCTAssertEqual(scale.pointsPerBead, 1.5)
        XCTAssertEqual(scale.points(beads: 35), 52.5)
    }

    func testOnA1xDisplayABeadIsOnePixelBecauseTwoWouldMakeThePet70Points() {
        let scale = PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 1)
        XCTAssertEqual(scale.pixelsPerBead, 1)
        XCTAssertEqual(scale.points(beads: 35), 35)
    }

    func testABoxNarrowerThanThePetTakesFewerPixelsPerBead() {
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: CGSize(width: 52.5, height: 52.5), backingScale: 2).pixelsPerBead, 3)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: CGSize(width: 52.4, height: 300), backingScale: 2).pixelsPerBead, 2)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: CGSize(width: 150, height: 40), backingScale: 2).points(beads: 35), 35)
    }

    func testABoxTooSmallForOnePixelPerBeadStillGetsOne() {
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: CGSize(width: 20, height: 20), backingScale: 1).pixelsPerBead, 1)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: .zero, backingScale: 2).pixelsPerBead, 1)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: CGSize(width: -10, height: 50), backingScale: 2).pixelsPerBead, 1)
    }

    func testABoxThatIsNotAFiniteNumberLimitsNothing() {
        let infinite = CGSize(width: CGFloat.infinity, height: .infinity)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: infinite, backingScale: 2).pixelsPerBead, 3)
        let unmeasured = CGSize(width: CGFloat.nan, height: .nan)
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: unmeasured, backingScale: 2).pixelsPerBead, 3)
    }

    func testABackingScaleThatIsNotPositiveCountsAsOne() {
        for backing in [0, -2, CGFloat.nan] {
            let scale = PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: backing)
            XCTAssertEqual(scale.pixelsPerBead, 1, "\(backing)")
            XCTAssertEqual(scale.backingScale, 1, "\(backing)")
        }
    }

    func testTheEarHeadOnRetinaIsThreePixelsPerBead() {
        let ear = CGSize(width: 34, height: 32)
        XCTAssertEqual(PetScaleRules.scale(beads: 16, fitting: ear, backingScale: 2).points(beads: 16), 24)
        XCTAssertEqual(PetScaleRules.scale(beads: 16, fitting: ear, backingScale: 1).points(beads: 16), 16)
    }

    func testAt3xABeadIsFourPixels() {
        let scale = PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 3)
        XCTAssertEqual(scale.pixelsPerBead, 4)
        XCTAssertEqual(scale.points(beads: 35), 140.0 / 3.0, accuracy: 1e-9)
    }

    func testTheOriginSnapsToTheNearestDevicePixel() {
        XCTAssertEqual(PetScaleRules.snapped(CGPoint(x: 10.3, y: 7.76), backingScale: 2), CGPoint(x: 10.5, y: 8))
        XCTAssertEqual(PetScaleRules.snapped(CGPoint(x: 10.3, y: 7.76), backingScale: 1), CGPoint(x: 10, y: 8))
        XCTAssertEqual(PetScaleRules.snapped(CGPoint(x: -0.3, y: 0.2), backingScale: 2), CGPoint(x: -0.5, y: 0))
    }

    func testAnimationOffsetsAreWholeBeadsAndKeepThePetOnTheGrid() {
        let retina = PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 2)
        XCTAssertEqual(retina.points(beads: 2), 3)
        XCTAssertEqual(retina.points(beads: -1), -1.5)
        let origin = PetScaleRules.snapped(CGPoint(x: 41.3, y: 12.2), backingScale: 2)
        let moved = origin.x + retina.points(beads: 3)
        XCTAssertEqual((moved * 2).rounded(), moved * 2, "a whole-bead step from a snapped origin lands on a device pixel")
        XCTAssertEqual(PetScaleRules.scale(beads: 35, fitting: habitat, backingScale: 1).points(beads: 2), 2)
    }
}
