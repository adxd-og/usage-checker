import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 "Manifest contract" and § 3.9 "Manifest
/// validation" (plan P5a R7, R14): the Swift check says what P4's art validator
/// (docs/superpowers/assets/p4/tools/validate.py) said for the same manifest. The table below
/// was made by writing each mutation of the "mouse" fixture to disk, running
/// `python3 -I validate.py` on it and recording its error count and verdict; a further 4,000
/// random mutations were compared once outside the suite with the same result. Cases where the
/// two differ on purpose (R7: `35.0`, a palette that is not an object) or the Swift check is
/// stricter are left out of the table and pinned on their own below.
final class PetManifestValidatorVerificationTests: XCTestCase {
    private typealias Row = (name: String, path: [String], value: Any?, errors: Int, passes: Bool)

    private static var parity: [Row] { [
        ("id_int", ["id"], 5, 1, false),
        ("id_null", ["id"], NSNull(), 1, false),
        ("name_nbsp", ["name"], "\u{A0}", 1, false),
        ("name_ideographic", ["name"], "\u{3000}", 1, false),
        ("name_ls", ["name"], "\u{2028}", 1, false),
        ("name_nel", ["name"], "\u{85}", 1, false),
        ("name_mongol", ["name"], "\u{180E}", 0, true),
        ("name_vt", ["name"], "\u{B}", 1, false),
        ("name_list", ["name"], ["a"], 1, false),
        ("size_str", ["size"], "35", 1, false),
        ("size_0", ["size"], 0, 6, false),
        ("size_neg", ["size"], -1, 6, false),
        ("size_35.5", ["size"], 35.5, 1, false),
        ("size_null", ["size"], NSNull(), 1, false),
        ("pal_empty", ["palettes"], [String: Any](), 18, false),
        ("pal_list", ["palettes"], [Any](), 18, false),
        ("pal_str", ["palettes"], "x", 18, false),
        ("pal_null", ["palettes"], NSNull(), 18, false),
        ("role_dot", ["palettes", "grey", "."], "#000000", 1, false),
        ("role_two", ["palettes", "grey", "ab"], "#000000", 1, false),
        ("role_empty", ["palettes", "grey", ""], "#000000", 1, false),
        ("role_astral", ["palettes", "grey", "\u{1F600}"], "#000000", 0, true),
        ("role_eacute", ["palettes", "grey", "\u{E9}"], "#000000", 0, true),
        ("role_e_comb", ["palettes", "grey", "e\u{301}"], "#000000", 1, false),
        ("role_comb_alone", ["palettes", "grey", "\u{301}"], "#000000", 0, true),
        ("role_zwj", ["palettes", "grey", "\u{200D}"], "#000000", 0, true),
        ("col_short", ["palettes", "grey", "o"], "#12345", 1, false),
        ("col_long", ["palettes", "grey", "o"], "#1234567", 1, false),
        ("col_nohash", ["palettes", "grey", "o"], "123456", 1, false),
        ("col_upper", ["palettes", "grey", "o"], "#ABCDEF", 0, true),
        ("col_nonascii", ["palettes", "grey", "o"], "#12345\u{661}", 1, false),
        ("col_int", ["palettes", "grey", "o"], 255, 1, false),
        ("col_null", ["palettes", "grey", "o"], NSNull(), 1, false),
        ("col_fullwidth", ["palettes", "grey", "o"], "#\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}", 1, false),
        ("col_g", ["palettes", "grey", "o"], "#12345g", 1, false),
        ("frames_empty", ["frames"], [String: Any](), 10, false),
        ("frames_list", ["frames"], [Any](), 10, false),
        ("frames_null", ["frames"], NSNull(), 10, false),
        ("frame_str", ["frames", "look"], "abc", 1, false),
        ("frame_short", ["frames", "look"], Array(PetFixture.frameRows.dropLast()), 1, false),
        ("frame_long", ["frames", "look"], PetFixture.frameRows + [String(repeating: ".", count: 35)], 1, false),
        ("frame_nonstr_row", ["frames", "look"], [5] + Array(PetFixture.frameRows.dropFirst()), 1, false),
        ("frame_row_long", ["frames", "look"], ["o1.................................."] + Array(PetFixture.frameRows.dropFirst()), 1, false),
        ("frame_row_comb", ["frames", "look"], ["o1................................e\u{301}"] + Array(PetFixture.frameRows.dropFirst()), 1, false),
        ("frame_row_astral", ["frames", "look"], ["\u{1F600}1................................."] + Array(PetFixture.frameRows.dropFirst()), 3, false),
        ("frame_row_space", ["frames", "look"], [" 1................................."] + Array(PetFixture.frameRows.dropFirst()), 3, false),
        ("frame_row_null", ["frames", "look"], [NSNull()] + Array(PetFixture.frameRows.dropFirst()), 1, false),
        ("frame_row_tab", ["frames", "look"], ["\u{9}1................................."] + Array(PetFixture.frameRows.dropFirst()), 3, false),
        ("ear_35", ["ear"], PetFixture.frameRows, 1, false),
        ("ear_str", ["ear"], "x", 1, false),
        ("ear_null", ["ear"], NSNull(), 1, false),
        ("ear_row_bad", ["ear"], ["z..............."] + Array(PetFixture.earRows.dropFirst()), 3, false),
        ("anim_missing_idle", ["animations", "idle"], nil, 1, false),
        ("anim_missing_all", ["animations"], [String: Any](), 5, false),
        ("anim_list", ["animations"], [Any](), 5, false),
        ("anim_null", ["animations"], NSNull(), 5, false),
        ("anim_str", ["animations", "walk"], "x", 2, false),
        ("anim_nofps", ["animations", "walk", "fps"], nil, 1, false),
        ("anim_fps_true", ["animations", "walk", "fps"], true, 1, false),
        ("anim_fps_false", ["animations", "walk", "fps"], false, 1, false),
        ("anim_fps_low", ["animations", "walk", "fps"], 0.49999, 1, false),
        ("anim_fps_edge_lo", ["animations", "walk", "fps"], 0.5, 0, true),
        ("anim_fps_edge_hi", ["animations", "walk", "fps"], 12, 0, true),
        ("anim_fps_hi", ["animations", "walk", "fps"], 12.0000001, 1, false),
        ("anim_fps_str", ["animations", "walk", "fps"], "8", 1, false),
        ("anim_fps_null", ["animations", "walk", "fps"], NSNull(), 1, false),
        ("anim_fps_zero", ["animations", "walk", "fps"], 0, 1, false),
        ("anim_frames_str", ["animations", "walk", "frames"], "walk_1", 1, false),
        ("anim_frames_empty", ["animations", "walk", "frames"], [Any](), 1, false),
        ("anim_frames_nonstr", ["animations", "walk", "frames"], [5], 1, false),
        ("anim_frames_unknown", ["animations", "walk", "frames"], ["x"], 1, false),
        ("anim_frames_null", ["animations", "walk", "frames"], nil, 1, false),
        ("anim_extra_ok", ["animations", "dance"], ["frames": ["look"], "fps": 3], 0, true),
        ("anim_extra_bad", ["animations", "dance"], ["frames": [Any](), "fps": 99], 2, false),
        ("still_missing", ["still", "look"], nil, 1, false),
        ("still_unknown", ["still", "look"], "zz", 1, false),
        ("still_all_missing", ["still"], [String: Any](), 3, false),
        ("still_list", ["still"], [Any](), 3, false),
        ("still_null", ["still"], NSNull(), 3, false),
        ("still_extra", ["still", "happy"], "look", 0, true),
        ("still_nonstr", ["still", "look"], 5, 1, false),
        ("still_null_val", ["still", "look"], NSNull(), 1, false),
        ("extra_key", ["sound"], "meow", 1, false),
        ("extra_key2", ["a"], 1, 1, false),
        ("key_ear_del", ["ear"], nil, 1, false),
        ("key_id_del", ["id"], nil, 1, false),
        ("key_still_del", ["still"], nil, 1, false),
        ("pal_missing_role", ["palettes", "white", "e"], nil, 1, false),
        ("pal_unused", ["palettes", "white", "w"], "#ffffff", 0, true),
    ] }

    private func check(_ object: [String: Any], folder: String = PetFixture.id) throws -> PetManifestCheck {
        PetManifestValidator.check(try PetFixture.data(object), folder: folder)
    }

    func testEachMutationGetsTheVerdictAndTheFaultCountTheArtValidatorGave() throws {
        for row in Self.parity {
            let object = PetFixture.setting(row.path, to: row.value, in: PetFixture.manifest())
            let result = try check(object)
            XCTAssertEqual(result.issues.count, row.errors, "\(row.name): \(result.issues.map(\.description))")
            XCTAssertEqual(result.manifest != nil, row.passes, row.name)
        }
    }

    /// validate.py reads `35.0` as a failing size and `true` as the size 1; R7 accepts the former
    /// as the number it is and both fail here.
    func testASizeThatIsAWholeFloatPassesAndABooleanNeverDoes() throws {
        XCTAssertEqual(try check(PetFixture.setting(["size"], to: 35.0, in: PetFixture.manifest())).issues, [])
        XCTAssertEqual(try check(PetFixture.setting(["size"], to: false, in: PetFixture.manifest())).issues.first, .badSize)
    }

    /// validate.py crashes on a palette that is not an object; here it is one issue and the pet
    /// stays out.
    func testAPaletteThatIsNotAnObjectIsAnIssueNotACrash() throws {
        for value: Any in ["x", [Any](), NSNull(), 5] {
            let result = try check(PetFixture.setting(["palettes", "grey"], to: value, in: PetFixture.manifest()))
            XCTAssertTrue(result.issues.contains(.paletteNotObject("grey")), "\(value)")
            XCTAssertNil(result.manifest)
        }
    }

    func testARoleOnlyTheEarPaintsMustBeInEveryPalette() throws {
        var object = PetFixture.setting(["ear"], to: PetFixture.rows(side: 16, beads: [(0, 0, "o"), (15, 15, "1"), (5, 5, "w")]), in: PetFixture.manifest())
        object = PetFixture.setting(["palettes", "grey", "w"], to: "#ffffff", in: object)
        XCTAssertEqual(try check(object).issues, [.paletteLacksRoles(palette: "white", roles: "w")])
        object = PetFixture.setting(["palettes", "white", "w"], to: "#fefefe", in: object)
        let fixed = try check(object)
        XCTAssertEqual(fixed.issues, [])
        XCTAssertEqual(fixed.notes, [], "a role only the ear paints is used, not unused")
    }

    func testAnEarBeadOfNoDeclaredRoleIsNamedWithItsPlace() throws {
        let ear = PetFixture.rows(side: 16, beads: [(0, 0, "o"), (15, 15, "1"), (5, 6, "z")])
        let issues = try check(PetFixture.setting(["ear"], to: ear, in: PetFixture.manifest())).issues
        XCTAssertEqual(issues, [
            .undeclaredRole(.ear, x: 5, y: 6, role: "z"),
            .paletteLacksRoles(palette: "grey", roles: "z"),
            .paletteLacksRoles(palette: "white", roles: "z"),
        ])
    }

    /// R14: a bead is one Unicode scalar. An emoji is two UTF-16 units and one grapheme, "é"
    /// typed as U+00E9 is one scalar; both are roles the art validator takes.
    func testARoleOfOneScalarIsOneBeadWhetherItIsAnEmojiOrAPrecomposedLetter() throws {
        var object = PetFixture.manifest()
        for palette in ["grey", "white"] {
            object = PetFixture.setting(["palettes", palette, "\u{1F600}"], to: "#123456", in: object)
            object = PetFixture.setting(["palettes", palette, "\u{E9}"], to: "#654321", in: object)
        }
        var row = Array(PetFixture.frameRows[0].unicodeScalars)
        row[2] = "\u{1F600}"
        row[3] = "\u{E9}"
        var rows = PetFixture.frameRows
        rows[0] = String(String.UnicodeScalarView(row))
        for frame in ["blink", "idle_1", "look", "sleep_1", "walk_1"] {
            object = PetFixture.setting(["frames", frame], to: rows, in: object)
        }
        let result = try check(object)
        XCTAssertEqual(result.issues, [])
        let pet = try XCTUnwrap(result.manifest)
        XCTAssertEqual(pet.frames["look"]?.bead(x: 2, y: 0), "\u{1F600}")
        XCTAssertEqual(pet.frames["look"]?.bead(x: 3, y: 0), "\u{E9}")
        XCTAssertEqual(pet.palettes["white"]?["\u{1F600}"], PetRGB(hex: "#123456"))
        let image = try XCTUnwrap(PetSpriteRenderer.image(try XCTUnwrap(pet.frames["look"]), palette: try XCTUnwrap(pet.palettes["grey"]), pixelsPerBead: 2))
        XCTAssertEqual(PetFixture.pixel(image, x: 4, y: 0), [0x12, 0x34, 0x56, 255])
        XCTAssertEqual(PetFixture.pixel(image, x: 6, y: 1), [0x65, 0x43, 0x21, 255])
    }

    /// The model, not only the verdict: every animation and every pose keeps its own frames and
    /// rate (a swap of idle and blink in the model would pass the contract check).
    func testEveryAnimationAndEveryStillKeepsItsOwnFramesAndRate() throws {
        let pet = try XCTUnwrap(try check(PetFixture.manifest()).manifest)
        XCTAssertEqual(pet.animations[.idle], PetAnimation(frames: ["idle_1"], fps: 2))
        XCTAssertEqual(pet.animations[.blink], PetAnimation(frames: ["blink"], fps: 6))
        XCTAssertEqual(pet.animations[.walk], PetAnimation(frames: ["walk_1", "idle_1"], fps: 8))
        XCTAssertEqual(pet.animations[.look], PetAnimation(frames: ["look"], fps: 1))
        XCTAssertEqual(pet.animations[.sleep], PetAnimation(frames: ["sleep_1"], fps: 1.5))
        XCTAssertEqual(pet.still[.idle], "idle_1")
        XCTAssertEqual(pet.still[.look], "look")
        XCTAssertEqual(pet.still[.sleep], "sleep_1")
        XCTAssertEqual(pet.palettes["grey"]?["o"], PetRGB(hex: "#101010"))
        XCTAssertEqual(pet.palettes["grey"]?["1"], PetRGB(hex: "#808080"))
        XCTAssertEqual(pet.palettes["white"]?["o"], PetRGB(hex: "#202020"))
    }

    func testTheModelOfAShippedPetIsTheFileItWasReadFrom() throws {
        let pets = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Pets", isDirectory: true)
        let library = PetLibrary.bundled()
        XCTAssertEqual(library.animalIDs.count, 4)
        for animal in library.animalIDs {
            let data = try Data(contentsOf: pets.appendingPathComponent(animal).appendingPathComponent("pet.json"))
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pet = try XCTUnwrap(library.manifests[animal])
            XCTAssertEqual(pet.id, raw["id"] as? String)
            XCTAssertEqual(pet.name, raw["name"] as? String)
            XCTAssertEqual(pet.size, raw["size"] as? Int)

            let palettes = try XCTUnwrap(raw["palettes"] as? [String: [String: String]])
            XCTAssertEqual(Set(pet.palettes.keys), Set(palettes.keys), animal)
            for (name, roles) in palettes {
                XCTAssertEqual(pet.palettes[name]?.count, roles.count, "\(animal) \(name)")
                for (role, hex) in roles {
                    let scalar = try XCTUnwrap(role.unicodeScalars.first)
                    XCTAssertEqual(pet.palettes[name]?[scalar], PetRGB(hex: hex), "\(animal) \(name) \(role)")
                }
            }

            let frames = try XCTUnwrap(raw["frames"] as? [String: [String]])
            XCTAssertEqual(Set(pet.frames.keys), Set(frames.keys), animal)
            for (name, rows) in frames {
                XCTAssertEqual(Self.rows(of: try XCTUnwrap(pet.frames[name])), rows, "\(animal) \(name)")
            }
            XCTAssertEqual(Self.rows(of: pet.ear), raw["ear"] as? [String], "\(animal) ear")

            let animations = try XCTUnwrap(raw["animations"] as? [String: [String: Any]])
            for name in PetAnimationName.allCases {
                let spec = try XCTUnwrap(animations[name.rawValue])
                XCTAssertEqual(pet.animations[name].frames, spec["frames"] as? [String], "\(animal) \(name)")
                XCTAssertEqual(pet.animations[name].fps, (spec["fps"] as? NSNumber)?.doubleValue, "\(animal) \(name)")
            }
            let stills = try XCTUnwrap(raw["still"] as? [String: String])
            for pose in PetPose.allCases {
                XCTAssertEqual(pet.still[pose], stills[pose.rawValue], "\(animal) \(pose)")
            }
        }
    }

    private static func rows(of map: PetCharMap) -> [String] {
        (0..<map.side).map { y in
            String(String.UnicodeScalarView((0..<map.side).map { x in map.bead(x: x, y: y) }))
        }
    }
}
