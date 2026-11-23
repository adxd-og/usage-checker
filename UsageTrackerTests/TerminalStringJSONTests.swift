import XCTest
@testable import Omelette

/// The rule applied to a whole JSON text: `TerminalString.cleaningStrings(inJSON:)`, the
/// function every read of `status.json` goes through.
/// Spec: docs/superpowers/specs/2026-11-23-terminal-strings.md § Design 3 (every string,
/// by construction) and 5 (nothing else moves).
final class TerminalStringJSONTests: XCTestCase {
    private func cleaned(_ json: String) -> String? {
        TerminalString.cleaningStrings(inJSON: Data(json.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A JSON `\uXXXX` escape for each UTF-16 unit of `text`, the way a writer that escapes
    /// everything spells it. Built here so that no escape stands in this file's source.
    private func escaped(_ text: String) -> String {
        text.utf16.map { "\\u" + String(repeating: "0", count: 4 - String($0, radix: 16).count) + String($0, radix: 16) }
            .joined()
    }

    // MARK: - Nothing to clean

    func testATextWithNothingToCleanComesBackByteForByte() throws {
        let compact = #"{"a":"x","b":[1,-2.5e3,true,false,null,{"c":"y z"}],"d":"","e":"caf\#u{E9} / \"q\" \\ 日本"}"#
        XCTAssertEqual(cleaned(compact), compact)

        let pretty = try TerminalStringFixture.fileBytes(TerminalStringFixture.cleanSnapshot())
        XCTAssertEqual(TerminalString.cleaningStrings(inJSON: pretty), pretty)
    }

    /// A clean string keeps the spelling its writer chose: an escaped slash, an escaped
    /// letter, a surrogate pair for an emoji.
    func testACleanStringKeepsItsWritersSpelling() {
        let json = "{\"a\":\"x\\/y\",\"b\":\"caf" + escaped("é") + "\",\"c\":\"" + escaped("👩\u{200D}💻") + "\"}"
        XCTAssertEqual(cleaned(json), json)
    }

    func testTabsAndCarriageReturnsBetweenTokensAreJSONsOwnWhitespace() {
        let json = "{\r\n\t\"a\" : \"x\",\r\n\t\"b\" : 1\r\n}\n"
        XCTAssertEqual(cleaned(json), json)
    }

    func testAnEmptyTextIsAnEmptyText() {
        XCTAssertEqual(TerminalString.cleaningStrings(inJSON: Data()), Data())
    }

    // MARK: - Strings that are cleaned

    func testARawControlAboveC0IsRemovedFromAString() {
        XCTAssertEqual(cleaned("{\"a\":\"x\u{9B}31my\u{7F}\u{202E}z\u{200B}\"}"), #"{"a":"x31myz"}"#)
    }

    func testAnEscapedControlIsRemovedFromAString() {
        let json = "{\"a\":\"x" + escaped("\u{1B}") + "[31my" + escaped("\u{9B}\u{202E}\u{200B}\u{0}") + "z\"}"
        XCTAssertEqual(cleaned(json), #"{"a":"x[31myz"}"#)
    }

    func testTheShortEscapesForALineBreakAndATabLeaveASpace() {
        XCTAssertEqual(cleaned(#"{"a":"fix\nbug","b":"fix\r\nbug","c":"fix\tbug","d":"x\by\fz"}"#),
                       #"{"a":"fix bug","b":"fix bug","c":"fix bug","d":"xy z"}"#)
    }

    func testAnEscapedSurrogatePairIsReadAsItsScalar() {
        // U+E0067, a tag character, as its two UTF-16 units: a format character, removed.
        let json = "{\"a\":\"flag" + escaped("\u{E0067}") + "\"}"
        XCTAssertEqual(cleaned(json), #"{"a":"flag"}"#)
    }

    /// A cleaned string is written again with its quotes and backslashes escaped, so the
    /// text is still JSON and still says the same thing.
    func testACleanedStringKeepsItsQuotesAndBackslashes() throws {
        let value = "a \"quoted\" \\ back/slash\u{1B}"
        let json = String(decoding: try JSONEncoder().encode(["k": value]), as: UTF8.self)
        let output = try XCTUnwrap(TerminalString.cleaningStrings(inJSON: Data(json.utf8)))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: output), ["k": "a \"quoted\" \\ back/slash"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), #"{"k":"a \"quoted\" \\ back/slash"}"#)
    }

    func testLeadingAndTrailingSpacesOfAStringAreTrimmed() {
        XCTAssertEqual(cleaned(#"{"a":" pad ","b":"in side"}"#), #"{"a":"pad","b":"in side"}"#)
    }

    func testAStringLeftWithNothingToShowIsTheUnseenMark() {
        let json = "{\"a\":\"" + escaped("\u{1B}\u{200B}") + "\",\"b\":\"\\n\",\"c\":\" \",\"d\":\"\"}"
        XCTAssertEqual(cleaned(json), #"{"a":"?","b":"?","c":"?","d":""}"#)
    }

    /// A key is a string like any other: `status --json` prints the file's keys too.
    func testKeysAreCleanedLikeValues() {
        XCTAssertEqual(cleaned("{\"na\u{200B}me" + escaped("\u{1B}") + "\":1}"), #"{"name":1}"#)
    }

    func testStringsAtAnyDepthAreCleaned() {
        let bad = "x\u{9B}y"
        let json = "[\"\(bad)\",{\"a\":[{\"b\":\"\(bad)\"},[\"\(bad)\"]]},\"\(bad)\"]"
        XCTAssertEqual(cleaned(json), #"["xy",{"a":[{"b":"xy"},["xy"]]},"xy"]"#)
    }

    /// Any JSON value, any string in it: what comes out decodes to the same value with
    /// every string cleaned, and holds no removed scalar raw or escaped.
    func testEveryStringOfAnEncodedValueIsCleanedWhateverItHolds() throws {
        var values: [String: [String]] = [:]
        for kind in TerminalStringFixture.kinds {
            values[kind.name + kind.text] = ["pre" + kind.text + "post", kind.text, kind.text + "x" + kind.text]
        }
        for encoder in [JSONEncoder(), StatusFile.encoder] {
            let output = try XCTUnwrap(TerminalString.cleaningStrings(inJSON: try encoder.encode(values)))
            let decoded = try JSONDecoder().decode([String: [String]].self, from: output)
            XCTAssertEqual(decoded.count, values.count)
            for (key, list) in values {
                XCTAssertEqual(decoded[TerminalString.clean(key)], list.map(TerminalString.clean), key.debugDescription)
            }
            TerminalStringFixture.assertNothingRemovedIsPrinted(TerminalStringFixture.Output(
                name: "an encoded dictionary", text: String(decoding: output, as: UTF8.self), shape: .json
            ))
        }
    }

    // MARK: - Bytes that are refused

    func testBytesThatAreNotUTF8AreRefused() {
        var bytes = Data("{\"a\":\"x".utf8)
        bytes.append(0x9B)   // the C1 CSI as one byte: a control to an 8-bit terminal
        bytes.append(Data("\"}".utf8))
        XCTAssertNil(TerminalString.cleaningStrings(inJSON: bytes))
        XCTAssertNil(TerminalString.cleaningStrings(inJSON: Data([0xFF, 0xFE])))
    }

    func testAByteOrderMarkBeforeTheTextIsRefused() {
        XCTAssertNil(cleaned("\u{FEFF}{\"a\":1}"))
    }

    func testUTF16IsRefused() throws {
        XCTAssertNil(TerminalString.cleaningStrings(inJSON: try XCTUnwrap("{\"a\":\"x\"}".data(using: .utf16))))
        XCTAssertNil(TerminalString.cleaningStrings(inJSON: try XCTUnwrap("{\"a\":\"x\"}".data(using: .utf16LittleEndian))))
    }

    /// Outside a string only JSON's own punctuation, numbers, literals and whitespace may
    /// stand: an escape after the closing brace is not copied to the output.
    func testAControlOrAnyOtherByteOutsideAStringIsRefused() {
        XCTAssertNil(cleaned("{\"a\":1}\u{1B}[2J"))
        XCTAssertNil(cleaned("{\"a\":1,\u{200B}\"b\":2}"))
        XCTAssertNil(cleaned("{\"a\":1} // note"))
        XCTAssertNil(cleaned("{\"a\":NaN}"))
        XCTAssertNil(cleaned("\u{0}"))
    }

    func testAStringThatNeverEndsIsRefused() {
        XCTAssertNil(cleaned(#"{"a":"x"#))
        XCTAssertNil(cleaned(#"{"a":"x\"#))
        XCTAssertNil(cleaned(#"{"a":"x\"}"#))
        XCTAssertNil(cleaned("\""))
    }

    /// What Foundation does not read as a JSON string is not guessed at.
    func testAStringFoundationCannotReadIsRefused() {
        XCTAssertNil(cleaned("{\"a\":\"" + "\\u" + "d800" + "\"}"), "a lone surrogate")
        XCTAssertNil(cleaned("{\"a\":\"x\ty\"}"), "a raw tab inside a string")
        XCTAssertNil(cleaned("{\"a\":\"x\u{1B}y\"}"), "a raw escape inside a string")
        XCTAssertNil(cleaned(#"{"a":"\x41"}"#), "an escape JSON does not have")
    }

    // MARK: - Size

    func testAMegabyteStringAndACharacterOfAHundredThousandMarksAreCleanedInOnePass() throws {
        let megabyte = String(repeating: "word \u{1B}[0m\u{9B}\n", count: 100_000)
        let giant = "e" + String(repeating: "\u{301}", count: 100_000)
        let json = try JSONEncoder().encode(["activity": megabyte, "name": "\u{202E}" + giant])
        XCTAssertGreaterThan(json.count, 1_000_000)

        let started = Date()
        let output = try XCTUnwrap(TerminalString.cleaningStrings(inJSON: json))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "linear: a megabyte is milliseconds")

        let decoded = try JSONDecoder().decode([String: String].self, from: output)
        XCTAssertTrue(decoded["activity"] == Array(repeating: "word [0m", count: 100_000).joined(separator: " "),
                      "each line break left one space and the last one none")
        XCTAssertEqual(decoded["name"]?.unicodeScalars.count, 100_001)
        XCTAssertEqual(decoded["name"]?.count, 1, "one character still")
    }

    func testManySmallStringsCostNoMoreThanTheirBytes() throws {
        let json = try JSONEncoder().encode((0..<50_000).map { "s\($0)\u{200B}" })
        let started = Date()
        let output = try XCTUnwrap(TerminalString.cleaningStrings(inJSON: json))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: output), (0..<50_000).map { "s\($0)" })
    }
}
