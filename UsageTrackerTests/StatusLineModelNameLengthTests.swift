import XCTest
@testable import Omelette

/// Spec 2026-11-20 small backlog 2 § B, the model name's length: `display_name` is
/// somebody else's string and nothing in the payload bounds it, so the status line prints
/// at most its first 64 characters, counted as a reader counts them (grapheme clusters).
/// The cut comes after the invisible characters are dropped and the name trimmed, and before
/// the check that a name of joiners and spaces is no name.
final class StatusLineModelNameLengthTests: XCTestCase {
    private func model(_ displayName: String) throws -> String? {
        let payload = try JSONSerialization.data(withJSONObject: ["model": ["display_name": displayName]])
        return StatusLineInput.parse(payload).model
    }

    /// 64 characters that are not all the same, so a cut at the wrong place shows.
    private let sixtyFour = String(repeating: "abcdefgh", count: 8)

    func testTheLimitIsSixtyFourCharacters() {
        XCTAssertEqual(StatusLineInput.maximumModelNameLength, 64)
    }

    func testANameOfSixtyFourCharactersStaysWhole() throws {
        XCTAssertEqual(try model(sixtyFour), sixtyFour)
        XCTAssertEqual(try model("Fable"), "Fable")
    }

    func testANameOfSixtyFiveCharactersLosesTheLast() throws {
        XCTAssertEqual(try model(sixtyFour + "X"), sixtyFour)
    }

    func testANameOfTenThousandCharactersKeepsItsFirstSixtyFour() throws {
        let long = String(repeating: "abcdefgh", count: 1_250)
        XCTAssertEqual(long.count, 10_000)
        XCTAssertEqual(try model(long), sixtyFour)
    }

    func testAJoinedEmojiAtTheCutStaysWhole() throws {
        // Man, woman and girl joined by U+200D: five scalars, one character, the 64th.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let name = String(repeating: "a", count: 63) + family + "b"
        XCTAssertEqual(
            try model(name).map { Array($0.unicodeScalars) },
            Array((String(repeating: "a", count: 63) + family).unicodeScalars)
        )
    }

    func testALetterAtTheCutKeepsItsMarks() throws {
        // e with a combining acute and a combining grave (U+0301, U+0300): one character.
        let accented = "e\u{301}\u{300}"
        let name = String(repeating: "a", count: 63) + accented + "b"
        XCTAssertEqual(
            try model(name).map { Array($0.unicodeScalars) },
            Array((String(repeating: "a", count: 63) + accented).unicodeScalars)
        )
    }

    func testACutThatEndsOnASpaceIsTrimmed() throws {
        let name = String(repeating: "a", count: 63) + " " + "Fable"
        XCTAssertEqual(try model(name), String(repeating: "a", count: 63))
    }

    func testInvisiblePaddingCannotPushTheNameOut() throws {
        // Zero-width spaces (U+200B) and a bidi override (U+202E) go before the cut.
        XCTAssertEqual(try model(String(repeating: "\u{200B}\u{202E}", count: 100) + "Fable"), "Fable")
    }

    func testLeadingSpacesCannotPushTheNameOut() throws {
        XCTAssertEqual(try model(String(repeating: " ", count: 100) + "Fable"), "Fable")
    }

    func testSixtyFourJoinersAreStillNoName() throws {
        XCTAssertNil(try model(String(repeating: "\u{200D}", count: 64)))
        XCTAssertNil(try model(String(repeating: "\u{200C}", count: 10_000)))
    }

    /// The name printed is the name checked: when the first 64 characters are joiners and
    /// spaces, what follows them is cut off and the line shows the generic name.
    func testSixtyFourCharactersOfJoinersAndSpacesAreNoNameWhateverFollows() throws {
        let name = String(repeating: "\u{200D} ", count: 64) + "Fable"
        XCTAssertNil(try model(name))
        let payload = try JSONSerialization.data(withJSONObject: [
            "model": ["display_name": name], "context_window": ["used_percentage": 42],
        ])
        let line = StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000),
            input: StatusLineInput.parse(payload), colour: false
        )
        XCTAssertEqual(line, "Claude [####------] 42%")
    }

    func testTheLineOfALongNamePrintsTheCutName() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "model": ["display_name": String(repeating: "abcdefgh", count: 1_250)],
            "context_window": ["used_percentage": 42],
        ])
        let line = StatusLineText.render(
            snapshot: nil, now: Date(timeIntervalSince1970: 1_800_000_000),
            input: StatusLineInput.parse(payload), colour: false
        )
        XCTAssertEqual(line, sixtyFour + " [####------] 42%")
    }

    // MARK: - The scalar limit: a character can be any size

    func testTheScalarLimitIsTwoHundredAndFiftySix() {
        XCTAssertEqual(StatusLineInput.maximumModelNameScalars, 256)
    }

    func testSixtyFourCharactersOfFourScalarsEachStayWhole() throws {
        // A letter under three combining acutes: four scalars, one character.
        let heavy = "a\u{0301}\u{0301}\u{0301}"
        let name = String(repeating: heavy, count: 64)
        XCTAssertEqual(name.count, 64)
        XCTAssertEqual(name.unicodeScalars.count, 256)
        XCTAssertEqual(try model(name).map { Array($0.unicodeScalars) }, Array(name.unicodeScalars))
    }

    func testOneScalarOverTheLimitDropsTheLastCharacterWhole() throws {
        let heavy = "a\u{0301}\u{0301}\u{0301}"
        let name = String(repeating: heavy, count: 63) + heavy + "\u{0301}"
        XCTAssertEqual(name.count, 64)
        XCTAssertEqual(name.unicodeScalars.count, 257)
        let cut = try XCTUnwrap(try model(name))
        XCTAssertEqual(cut.count, 63, "the last character went whole, not one of its marks")
        XCTAssertEqual(Array(cut.unicodeScalars), Array(String(repeating: heavy, count: 63).unicodeScalars))
    }

    func testALetterUnderAHundredThousandMarksIsNoName() throws {
        let name = "a" + String(repeating: "\u{0301}", count: 100_000)
        XCTAssertEqual(name.count, 1, "one character, as a reader counts")
        XCTAssertNil(try model(name))
    }

    func testAnEndlessChainOfJoinedEmojiIsNoName() throws {
        // Ten thousand men joined by U+200D: one character of twenty thousand scalars.
        let name = String(repeating: "\u{1F468}\u{200D}", count: 10_000) + "\u{1F468}"
        XCTAssertEqual(name.count, 1)
        XCTAssertNil(try model(name))
    }

    func testAHeavyCharacterAfterANameCostsOnlyItself() throws {
        let name = "Fable e" + String(repeating: "\u{0301}", count: 300)
        XCTAssertEqual(try model(name), "Fable", "the heavy letter went, and the space the cut left with it")
    }

    func testAFamilyEmojiAndAPersianWordAreFarUnderTheLimit() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
        XCTAssertEqual(try model(family).map { Array($0.unicodeScalars) }, Array(family.unicodeScalars))
        XCTAssertEqual(try model(persian).map { Array($0.unicodeScalars) }, Array(persian.unicodeScalars))
    }
}
