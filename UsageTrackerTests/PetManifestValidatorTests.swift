import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Manifest contract" and § 3.9 "Manifest validation", check
/// by check as P4's art validator (tools/validate.py) made them: exactly the contract's keys,
/// id = folder, a name, size 35, one-character roles other than ".", #rrggbb colours, square
/// maps of declared roles, every palette colouring every used role, the five animations with
/// existing frames at 0.5–12 fps, a still per pose, a 16 × 16 ear. Roles no map uses are a
/// note, not an issue.
final class PetManifestValidatorTests: XCTestCase {
    private func check(_ object: [String: Any], folder: String = PetFixture.id) throws -> PetManifestCheck {
        let data = try PetFixture.data(object)
        return PetManifestValidator.check(data, folder: folder)
    }

    private func with(_ path: [String], _ value: Any?) -> [String: Any] {
        PetFixture.setting(path, to: value, in: PetFixture.manifest())
    }

    func testAManifestThatKeepsTheContractComesBackAsAPet() throws {
        let result = try check(PetFixture.manifest())
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.notes, [])
        let pet = try XCTUnwrap(result.manifest)
        XCTAssertEqual(pet.id, "mouse")
        XCTAssertEqual(pet.name, "Mouse")
        XCTAssertEqual(pet.size, 35)
        XCTAssertEqual(pet.paletteNames, ["grey", "white"])
        XCTAssertEqual(pet.palettes["white"]?["e"], PetRGB(hex: "#0a0b0c"))
        XCTAssertEqual(pet.frames.keys.sorted(), ["blink", "idle_1", "look", "sleep_1", "walk_1"])
        XCTAssertEqual(pet.frames["idle_1"]?.bead(x: 34, y: 34), "e")
        XCTAssertEqual(pet.animations[.walk], PetAnimation(frames: ["walk_1", "idle_1"], fps: 8))
        XCTAssertEqual(pet.animations[.sleep].fps, 1.5)
        XCTAssertEqual(pet.still[.look], "look")
        XCTAssertEqual(pet.ear.side, 16)
        XCTAssertEqual(pet.ear.bead(x: 15, y: 15), "1")
    }

    func testJSONThatDoesNotParseIsUnreadable() {
        let result = PetManifestValidator.check(Data("{\"id\": ".utf8), folder: "mouse")
        XCTAssertEqual(result.issues, [.unreadable])
        XCTAssertNil(result.manifest)
    }

    func testJSONThatIsNotAnObjectMissesEveryKey() {
        let result = PetManifestValidator.check(Data("[1, 2]".utf8), folder: "mouse")
        XCTAssertEqual(result.issues, [.missingKeys(PetContract.keys)])
    }

    func testAMissingKeyStopsTheCheckAfterTheKeyLine() throws {
        var object = with(["ear"], nil)
        object["sound"] = "meow"
        object["size"] = 12
        XCTAssertEqual(try check(object).issues, [.missingKeys(["ear"]), .extraKeys(["sound"])])
    }

    func testAKeyOutsideTheContractFailsTheManifest() throws {
        let result = try check(with(["sound"], "meow"))
        XCTAssertEqual(result.issues, [.extraKeys(["sound"])])
        XCTAssertNil(result.manifest)
    }

    func testTheIdMustNameItsFolder() throws {
        XCTAssertEqual(try check(PetFixture.manifest(), folder: "rat").issues, [.idMismatch(id: "mouse", folder: "rat")])
    }

    func testTheNameMustNotBeBlank() throws {
        XCTAssertEqual(try check(with(["name"], "  ")).issues, [.emptyName])
        XCTAssertEqual(try check(with(["name"], 7)).issues, [.emptyName])
    }

    func testTheSizeMustBeTheNumber35() throws {
        XCTAssertEqual(try check(with(["size"], "35")).issues, [.badSize])
        XCTAssertEqual(try check(with(["size"], true)).issues, [.badSize])
        let small = try check(with(["size"], 32)).issues
        XCTAssertEqual(small.first, .badSize)
        XCTAssertTrue(small.contains(.rowCount(.frame("idle_1"), expected: 32)), "the maps are measured against the size given")
    }

    func testAManifestWithoutPalettesFailsAndNoBeadIsDeclared() throws {
        let issues = try check(with(["palettes"], [String: Any]())).issues
        XCTAssertEqual(issues.first, .noPalettes)
        XCTAssertTrue(issues.contains(.undeclaredRole(.frame("idle_1"), x: 0, y: 0, role: "o")))
    }

    func testARoleIsOneCharacterAndNeverTheTransparentBead() throws {
        var object = with(["palettes", "grey", "."], "#000000")
        object = PetFixture.setting(["palettes", "grey", "ab"], to: "#000000", in: object)
        XCTAssertEqual(try check(object).issues, [
            .transparentRole(palette: "grey"),
            .roleNotOneCharacter(palette: "grey", role: "ab"),
        ])
    }

    /// The art validator counts code points: "e" + U+0301, one Swift Character, is a role two
    /// long and makes a row 36 beads long (plan review finding 1).
    func testACombiningAccentIsTwoBeadsAsInTheArtValidator() throws {
        let accented = "e\u{301}"
        var object = PetFixture.manifest()
        for palette in ["grey", "white"] {
            object = PetFixture.setting(["palettes", palette, "e"], to: nil, in: object)
            object = PetFixture.setting(["palettes", palette, accented], to: "#000000", in: object)
        }
        let rows = PetFixture.rows(side: 35, beads: [(0, 0, "o"), (1, 0, "1"), (34, 34, Character(accented))])
        for frame in ["blink", "idle_1", "look", "sleep_1", "walk_1"] {
            object = PetFixture.setting(["frames", frame], to: rows, in: object)
        }
        let result = try check(object)
        XCTAssertEqual(result.issues, [
            .roleNotOneCharacter(palette: "grey", role: accented),
            .roleNotOneCharacter(palette: "white", role: accented),
            .rowLength(.frame("blink"), row: 34, expected: 35),
            .rowLength(.frame("idle_1"), row: 34, expected: 35),
            .rowLength(.frame("look"), row: 34, expected: 35),
            .rowLength(.frame("sleep_1"), row: 34, expected: 35),
            .rowLength(.frame("walk_1"), row: 34, expected: 35),
        ])
        XCTAssertNil(result.manifest)
    }

    func testAColourMustBeAHashAndSixHexDigits() throws {
        XCTAssertEqual(try check(with(["palettes", "grey", "o"], "#12345")).issues, [.badColour(palette: "grey", role: "o")])
        XCTAssertEqual(try check(with(["palettes", "white", "e"], 255)).issues, [.badColour(palette: "white", role: "e")])
    }

    func testEveryBeadIsTransparentOrADeclaredRole() throws {
        var rows = PetFixture.frameRows
        rows[2] = PetFixture.rows(side: 35, beads: [(3, 0, "z")])[0]
        XCTAssertEqual(try check(with(["frames", "look"], rows)).issues, [
            .undeclaredRole(.frame("look"), x: 3, y: 2, role: "z"),
            .paletteLacksRoles(palette: "grey", roles: "z"),
            .paletteLacksRoles(palette: "white", roles: "z"),
        ])
    }

    func testEveryMapIsSquareAtItsSize() throws {
        var object = with(["frames", "idle_1"], Array(PetFixture.frameRows.dropLast()))
        var ear = PetFixture.earRows
        ear[5].removeLast()
        object = PetFixture.setting(["ear"], to: ear, in: object)
        XCTAssertEqual(try check(object).issues, [
            .rowCount(.frame("idle_1"), expected: 35),
            .rowLength(.ear, row: 5, expected: 16),
        ])
    }

    func testEveryPaletteDefinesEveryRoleUsed() throws {
        XCTAssertEqual(try check(with(["palettes", "white", "e"], nil)).issues, [.paletteLacksRoles(palette: "white", roles: "e")])
    }

    func testARoleNoMapUsesIsReportedNotFailed() throws {
        var object = with(["palettes", "grey", "w"], "#ffffff")
        object = PetFixture.setting(["palettes", "white", "w"], to: "#eeeeee", in: object)
        object = PetFixture.setting(["palettes", "white", "3"], to: "#dddddd", in: object)
        let result = try check(object)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.notes, [.unusedRoles("3w")])
        XCTAssertNotNil(result.manifest)
    }

    func testEveryRequiredAnimationIsThere() throws {
        XCTAssertEqual(try check(with(["animations", "blink"], nil)).issues, [.missingAnimation(.blink)])
    }

    func testAnAnimationsFramesExist() throws {
        var object = with(["animations", "walk", "frames"], [String]())
        object = PetFixture.setting(["animations", "look", "frames"], to: ["look", "nope"], in: object)
        XCTAssertEqual(try check(object).issues, [
            .animationUnknownFrame(animation: "look", frame: "nope"),
            .animationWithoutFrames("walk"),
        ])
    }

    func testAnAnimationRunsAt0Point5To12Fps() throws {
        XCTAssertEqual(try check(with(["animations", "walk", "fps"], 0.5)).issues, [])
        XCTAssertEqual(try check(with(["animations", "walk", "fps"], 12)).issues, [])
        let refused: [Any] = [0.4, 12.5, true, "8"]
        for fps in refused {
            XCTAssertEqual(try check(with(["animations", "walk", "fps"], fps)).issues, [.animationFps("walk")], "\(fps)")
        }
        XCTAssertEqual(try check(with(["animations", "walk", "fps"], nil)).issues, [.animationFps("walk")])
    }

    func testAnAnimationBeyondTheRequiredFiveIsCheckedToo() throws {
        let object = with(["animations", "dance"], PetFixture.animation(["twirl"], fps: 4))
        XCTAssertEqual(try check(object).issues, [.animationUnknownFrame(animation: "dance", frame: "twirl")])
    }

    func testEveryPoseHasAStillFrameThatExists() throws {
        var object = with(["still", "look"], nil)
        object = PetFixture.setting(["still", "sleep"], to: "nap", in: object)
        XCTAssertEqual(try check(object).issues, [.stillMissing(.look), .stillUnknownFrame(.sleep, frame: "nap")])
    }

    func testTheEarIs16By16() throws {
        XCTAssertEqual(try check(with(["ear"], PetFixture.frameRows)).issues, [.rowCount(.ear, expected: 16)])
    }
}
