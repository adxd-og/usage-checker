import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Manifest contract": what a manifest's parts become in
/// the app — palette colours from "#rrggbb", char maps read top row first, the five required
/// animations and the still per pose reached by name, a sprite naming a frame or the ear head.
final class PetManifestTests: XCTestCase {
    func testAColourIsAHashAndSixHexDigitsInEitherCase() throws {
        let colour = try XCTUnwrap(PetRGB(hex: "#3a1D10"))
        XCTAssertEqual([colour.red, colour.green, colour.blue], [0x3a, 0x1d, 0x10])
        XCTAssertNotNil(PetRGB(hex: "#FFFFFF"))
        XCTAssertEqual(PetRGB(hex: "#FFFFFF"), PetRGB(hex: "#ffffff"))
    }

    func testAnythingElseIsNotAColour() {
        for text in ["", "3a1d10", "#3a1d1", "#3a1d100", "#3a1d1g", "#+a1d10", " #3a1d10", "#3a1d10\n"] {
            XCTAssertNil(PetRGB(hex: text), text)
        }
    }

    func testACharMapReadsTopRowFirst() throws {
        let map = try XCTUnwrap(PetCharMap(rows: ["ab", "c."], side: 2))
        XCTAssertEqual(map.bead(x: 0, y: 0), "a")
        XCTAssertEqual(map.bead(x: 1, y: 0), "b")
        XCTAssertEqual(map.bead(x: 0, y: 1), "c")
        XCTAssertEqual(map.bead(x: 1, y: 1), ".")
        XCTAssertEqual(map.roles, ["a", "b", "c"])
    }

    func testACharMapOfTheWrongShapeIsRefused() {
        XCTAssertNil(PetCharMap(rows: ["ab"], side: 2), "one row short")
        XCTAssertNil(PetCharMap(rows: ["ab", "c"], side: 2), "a row one bead short")
        XCTAssertNil(PetCharMap(rows: ["ab", "cde"], side: 2), "a row one bead long")
        XCTAssertNil(PetCharMap(rows: [], side: 0), "no beads")
        XCTAssertNil(PetCharMap(rows: ["e\u{301}"], side: 1), "e + a combining accent is two beads, as in the art validator")
    }

    func testTheRequiredAnimationsAndStillsAreReachedByNameAndPose() {
        let animations = PetAnimations(
            idle: PetAnimation(frames: ["idle_1", "idle_2"], fps: 2),
            blink: PetAnimation(frames: ["blink"], fps: 6),
            walk: PetAnimation(frames: ["walk_1"], fps: 8),
            look: PetAnimation(frames: ["look"], fps: 1),
            sleep: PetAnimation(frames: ["sleep_1"], fps: 1.5)
        )
        XCTAssertEqual(
            PetAnimationName.allCases.map { animations[$0].frames.first },
            ["idle_1", "blink", "walk_1", "look", "sleep_1"]
        )
        XCTAssertEqual(animations[.sleep].fps, 1.5)
        let stills = PetStills(idle: "idle_1", look: "look", sleep: "sleep_1")
        XCTAssertEqual(PetPose.allCases.map { stills[$0] }, ["idle_1", "look", "sleep_1"])
    }

    func testASpriteNamesAFrameOrTheEarHead() throws {
        let frame = try XCTUnwrap(PetCharMap(rows: ["o"], side: 1))
        let ear = try XCTUnwrap(PetCharMap(rows: ["e"], side: 1))
        let grey = try XCTUnwrap(PetRGB(hex: "#101010"))
        let animation = PetAnimation(frames: ["idle_1"], fps: 2)
        let manifest = PetManifest(
            id: "mouse",
            name: "Mouse",
            size: 1,
            palettes: ["grey": ["o": grey]],
            frames: ["idle_1": frame],
            animations: PetAnimations(idle: animation, blink: animation, walk: animation, look: animation, sleep: animation),
            still: PetStills(idle: "idle_1", look: "idle_1", sleep: "idle_1"),
            ear: ear
        )
        XCTAssertEqual(manifest.map(.frame("idle_1")), frame)
        XCTAssertEqual(manifest.map(.ear), ear)
        XCTAssertNil(manifest.map(.frame("dance")))
        XCTAssertEqual(manifest.paletteNames, ["grey"])
        XCTAssertEqual(PetSprite.frame("idle_1").description, "frame idle_1")
        XCTAssertEqual(PetSprite.ear.description, "ear")
    }
}
