import XCTest
@testable import Omelette

/// Second round of verification of notch-island spec 2026-10-29 § 3.9 `PetScaleRules`: a box that
/// is exactly as big as the sprite at N pixels per bead gets N, even where the division lands one
/// ulp under N in floating point (the rule's tolerance exists for this; the mutation check found
/// no test that needed it).
final class PetScaleRulesVerification2Tests: XCTestCase {
    func testABoxExactlyAsBigAsTheSpriteTakesTheFullPixelsAtAFractionalBackingScale() {
        // (beads, backing scale, pixels per bead): beads * n / backing, divided back, is n - 1 ulp.
        let cases: [(Int, CGFloat, Int)] = [(35, 2.6, 3), (16, 2.7, 3), (16, 2.8, 3), (16, 1.9, 2)]
        for (beads, backing, pixels) in cases {
            let side = CGFloat(beads * pixels) / backing
            XCTAssertLessThan(side * backing / CGFloat(beads), CGFloat(pixels), "the case is one where floating point lands under")
            let scale = PetScaleRules.scale(beads: beads, fitting: CGSize(width: side, height: 300), backingScale: backing)
            XCTAssertEqual(scale.pixelsPerBead, pixels, "\(beads) beads in \(side) pt at \(backing)x")
        }
    }
}
