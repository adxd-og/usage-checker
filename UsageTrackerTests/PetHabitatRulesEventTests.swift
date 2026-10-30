import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": a lift raises the sprite in whole
/// beads and never leaves the column: its top stops at the column's top.
final class PetHabitatRulesEventTests: XCTestCase {
    private let retina = PetScaleRules.Scale(pixelsPerBead: 3, backingScale: 2)
    private let plain = PetScaleRules.Scale(pixelsPerBead: 1, backingScale: 1)

    private func y(_ lift: Int, footY: CGFloat, scale: PetScaleRules.Scale) -> CGFloat {
        PetHabitatRules.origin(xBeads: 10, yBeads: lift, footY: footY, petBeads: 35, roamBeads: 65, scale: scale).y
    }

    func testTheRoomIsTheWholeBeadsBetweenTheFloorAndTheColumnsTop() {
        XCTAssertEqual(PetHabitatRules.liftRoom(footY: 86, petBeads: 35, scale: retina), 22, "the short column of the 80-bead climb")
        XCTAssertEqual(PetHabitatRules.liftRoom(footY: 566, petBeads: 35, scale: retina), 342)
        XCTAssertEqual(PetHabitatRules.liftRoom(footY: 100, petBeads: 35, scale: plain), 65)
        XCTAssertEqual(PetHabitatRules.liftRoom(footY: 52.5, petBeads: 35, scale: retina), 0)
        XCTAssertEqual(PetHabitatRules.liftRoom(footY: 10, petBeads: 35, scale: retina), 0, "never below nothing")
    }

    func testALiftRaisesTheSpriteInWholeBeadsAndLeavesItsXAlone() {
        XCTAssertEqual(
            PetHabitatRules.origin(xBeads: 10, yBeads: 20, footY: 566, petBeads: 35, roamBeads: 65, scale: retina),
            CGPoint(x: 15, y: 483.5)
        )
        XCTAssertEqual(y(120, footY: 566, scale: retina), 333.5, "the contract's highest, in a tall column")
        XCTAssertEqual(y(20, footY: 566, scale: plain), 511)
    }

    func testNoLiftIsTheFloorAndBelowItIsTheFloorToo() {
        XCTAssertEqual(y(0, footY: 566, scale: retina), 513.5)
        XCTAssertEqual(y(-5, footY: 566, scale: retina), 513.5)
        XCTAssertEqual(
            PetHabitatRules.origin(xBeads: 10, footY: 566, petBeads: 35, roamBeads: 65, scale: retina).y, 513.5,
            "a caller with no lift"
        )
    }

    func testALiftStopsAtTheColumnsTopOnAWholeBead() {
        XCTAssertEqual(y(120, footY: 86, scale: retina), 0.5, "22 beads of room: 33 of the 33.5 pt")
        XCTAssertEqual(y(120, footY: 100, scale: plain), 0, "65 beads of room")
        XCTAssertEqual(y(120, footY: 52.5, scale: retina), 0, "no room at all")
    }

    func testNoLiftEverLeavesTheColumn() {
        for scale in [retina, plain] {
            let side = scale.points(beads: 35)
            for footY in stride(from: side, through: 700, by: 7.25) {
                for lift in 0...120 {
                    let top = y(lift, footY: footY, scale: scale)
                    XCTAssertGreaterThanOrEqual(top, 0, "foot \(footY), lift \(lift)")
                    XCTAssertLessThanOrEqual(top, footY - side + 0.5, "foot \(footY), lift \(lift)")
                }
            }
        }
    }
}
