import XCTest
@testable import Omelette

/// The rule for one string on its way to a terminal: `TerminalString.clean` and the
/// `isInvisible` it shares with the status line's model name.
/// Spec: docs/superpowers/specs/2026-11-23-terminal-strings.md § Design 1 (one rule),
/// 2 (a line stays readable), 5 (no length cap) and 6 (the status line shares the core).
final class TerminalStringTests: XCTestCase {
    private func clean(_ text: String) -> String { TerminalString.clean(text) }

    private func scalars(_ text: String) -> [String] {
        text.unicodeScalars.map { "U+" + String($0.value, radix: 16, uppercase: true) }
    }

    // MARK: - Design 1: which scalars go

    /// Every scalar there is: `isInvisible` is true for exactly `Cc`, `Cf` but the two
    /// joiners, `Zl` and `Zp`, and `clean` removes exactly those from between two letters.
    /// The removed ones go through in groups between sentinels, the kept ones one string
    /// per plane-sized block, each compared scalar by scalar.
    func testExactlyTheInvisibleCategoriesGoAcrossAllOfUnicode() {
        var removed: [Unicode.Scalar] = []
        var kept: [Unicode.Scalar] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let expected: Bool
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: expected = true
            case .format: expected = value != 0x200C && value != 0x200D
            default: expected = false
            }
            if TerminalString.isInvisible(scalar) != expected {
                XCTFail("isInvisible is wrong for U+\(String(value, radix: 16, uppercase: true))")
            }
            if expected { removed.append(scalar) } else { kept.append(scalar) }
        }
        XCTAssertGreaterThan(removed.count, 150)
        XCTAssertGreaterThan(kept.count, 1_000_000)
        XCTAssertFalse(removed.contains("\u{200C}"))
        XCTAssertFalse(removed.contains("\u{200D}"))

        // The removed: nothing but the sentinels is left, and no space where none of the
        // group broke a line.
        for scalar in removed {
            var view = String.UnicodeScalarView()
            view.append("x")
            view.append(scalar)
            view.append("y")
            let expected = TerminalString.isLineBreakOrTab(scalar) ? "x y" : "xy"
            XCTAssertEqual(clean(String(view)), expected, "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }

        // The kept, in blocks between sentinels: each comes out where it went in. A space
        // separator stays inside a string like any other kept scalar.
        var start = 0
        while start < kept.count {
            let block = kept[start..<min(start + 4096, kept.count)]
            start += block.count
            var view = String.UnicodeScalarView()
            view.append("x")
            view.append(contentsOf: block)
            view.append("y")
            let cleaned = clean(String(view))
            XCTAssertTrue(cleaned.unicodeScalars.elementsEqual(view),
                          "kept scalars from U+\(String(block.first!.value, radix: 16, uppercase: true))")
        }
    }

    /// The tab and the line breaks the spec lists, and no other scalar, are what leaves a
    /// space: U+0009 to U+000D, U+0085, U+2028, U+2029.
    func testOnlyTheTabAndTheLineBreaksLeaveASpace() {
        var breaks: [UInt32] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if TerminalString.isLineBreakOrTab(scalar) { breaks.append(value) }
        }
        XCTAssertEqual(breaks, [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029])
    }

    func testEachKindOfHostileStringGoesAndLeavesWhatTheSpecSays() {
        for kind in TerminalStringFixture.kinds {
            let cleaned = clean("pre" + kind.text + "post")
            XCTAssertEqual(cleaned, "pre" + kind.leaves + "post", kind.name)
            XCTAssertEqual(TerminalStringFixture.removed(in: cleaned), [], kind.name)
        }
    }

    /// An escape sequence loses the scalar that made it one. What it was written with is
    /// ordinary text and stays: the rule removes scalars, it does not parse sequences.
    func testAnEscapeSequenceIsLeftAsTheTextItWasWrittenWith() {
        XCTAssertEqual(clean("\u{1B}[31mred\u{1B}[0m"), "[31mred[0m")
        XCTAssertEqual(clean("\u{1B}]52;c;aGVsbG8=\u{07}"), "]52;c;aGVsbG8=")
        XCTAssertEqual(clean("\u{1B}]52;c;aGVsbG8=\u{1B}\\"), "]52;c;aGVsbG8=\\")
        XCTAssertEqual(clean("\u{9B}31mred"), "31mred")
    }

    func testAStringWithNothingToCleanComesBackScalarForScalar() {
        for text in [
            "Usage tracker", "Max 5x", "café", "cafe\u{301}", "src/app\\core", "\"quoted\"",
            "a  b", "日本語のプロジェクト", "می\u{200C}خواهم", "👩\u{200D}💻", "🏳️\u{200D}🌈", "x\u{00A0}y", "",
        ] {
            XCTAssertEqual(scalars(clean(text)), scalars(text), text)
        }
    }

    func testCleaningACleanedStringChangesNothing() {
        let inputs = TerminalStringFixture.kinds.map { "pre" + $0.text + "post" }
            + [TerminalStringFixture.hostile("word"), " \u{200D} x \u{200D} ", "\u{1B}", "", "   ", "a \n b"]
        for text in inputs {
            let once = clean(text)
            XCTAssertEqual(scalars(clean(once)), scalars(once), text.debugDescription)
        }
    }

    // MARK: - Design 2: a line stays readable

    func testALineBreakBetweenTwoWordsLeavesOneSpace() {
        XCTAssertEqual(clean("fix\nbug"), "fix bug")
        XCTAssertEqual(clean("fix\tbug"), "fix bug")
    }

    func testCRLFIsOneRunAndLeavesOneSpace() {
        XCTAssertEqual(clean("fix\r\nbug"), "fix bug")
    }

    func testARunOfSeveralBreaksAndControlsLeavesOneSpace() {
        XCTAssertEqual(clean("fix\n\n\r\n\t\u{2028}bug"), "fix bug")
        XCTAssertEqual(clean("fix\u{202E}\n\u{200B}bug"), "fix bug", "the break may stand anywhere in the run")
        XCTAssertEqual(clean("fix\n\u{1B}\tbug"), "fix bug")
    }

    func testARunWithNoBreakInItLeavesNothing() {
        XCTAssertEqual(clean("fix\u{202E}bug"), "fixbug", "a bidi control between two words")
        XCTAssertEqual(clean("fix\u{1B}\u{200B}\u{7F}bug"), "fixbug")
    }

    /// The space the break would leave is already there: none is added on either side.
    func testABreakNextToASpaceAddsNoSecondSpace() {
        XCTAssertEqual(clean("fix \nbug"), "fix bug")
        XCTAssertEqual(clean("fix\n bug"), "fix bug")
        XCTAssertEqual(clean("fix\u{00A0}\nbug"), "fix\u{00A0}bug", "a no-break space is a space")
    }

    /// Spaces inside are left as they are: the two around a break are still two.
    func testRunsOfSpacesAreNotCollapsed() {
        XCTAssertEqual(clean("a  b"), "a  b")
        XCTAssertEqual(clean("a \n b"), "a  b")
    }

    func testABreakAtTheStartOrTheEndLeavesNothing() {
        XCTAssertEqual(clean("\nfix"), "fix")
        XCTAssertEqual(clean("fix\n"), "fix")
        XCTAssertEqual(clean("\r\n\tfix bug\u{2029}"), "fix bug")
    }

    func testLeadingAndTrailingSpacesAreTrimmed() {
        XCTAssertEqual(clean("  a  b  "), "a  b")
        XCTAssertEqual(clean("\u{3000}a\u{00A0}"), "a", "every space separator, not U+0020 alone")
        XCTAssertEqual(clean(" \u{1B} a \u{200B} "), "a", "a space left at an end by what was removed")
    }

    /// The joiners are kept and looked through: the break still separates the two words
    /// around them, and a joiner with nothing visible before it gets no space.
    func testAJoinerBesideABreakIsLookedThrough() {
        XCTAssertEqual(scalars(clean("fix\u{200D}\nbug")), scalars("fix\u{200D} bug"))
        XCTAssertEqual(scalars(clean("fix\n\u{200D}bug")), scalars("fix\u{200D} bug"))
        XCTAssertEqual(scalars(clean("a \u{200D}\nb")), scalars("a \u{200D}b"))
        XCTAssertEqual(scalars(clean("\u{200D}\nb")), scalars("\u{200D}b"))
    }

    /// Only spaces are trimmed. A joiner at an end stays, as it does in the status line's
    /// model name.
    func testAJoinerAtAnEndStays() {
        XCTAssertEqual(scalars(clean(" \u{200D} x \u{200D} ")), scalars("\u{200D} x \u{200D}"))
    }

    // MARK: - Nothing left to show

    func testAStringOfNothingButRemovedScalarsIsTheUnseenMark() {
        XCTAssertEqual(TerminalString.unseen, "?")
        XCTAssertEqual(clean("\u{1B}"), "?")
        XCTAssertEqual(clean("\u{1B}\u{9B}\u{202E}\u{200B}\r\n"), "?")
        XCTAssertEqual(clean("\u{E0067}\u{E0062}\u{E007F}"), "?")
        for kind in TerminalStringFixture.kinds where kind.leaves == "" || kind.leaves == " " {
            XCTAssertEqual(clean(kind.text), "?", kind.name)
        }
    }

    /// The joiners alone, or with spaces and removed scalars, show nothing either: they
    /// are kept only in a string that has something else to show.
    func testJoinersAloneAreNotAVisibleValue() {
        XCTAssertEqual(clean("\u{200D}"), "?")
        XCTAssertEqual(clean("\u{200C}\u{200D}\u{200C}"), "?")
        XCTAssertEqual(clean(" \u{200D} \u{200B}\n\u{200C} "), "?")
    }

    func testSpacesAloneAreNotAVisibleValue() {
        XCTAssertEqual(clean("   "), "?")
        XCTAssertEqual(clean("\u{00A0}\u{3000}"), "?")
    }

    /// The app's own empty string is not something the rule emptied, and stays empty.
    func testAnEmptyStringStaysEmpty() {
        XCTAssertEqual(clean(""), "")
    }

    func testTheUnseenMarkIsItselfClean() {
        XCTAssertEqual(clean(TerminalString.unseen), TerminalString.unseen)
    }

    // MARK: - Clusters and joiners

    func testAnEmojiJoinedByZWJStaysOneCharacter() {
        let family = "👩\u{200D}👩\u{200D}👧\u{200D}👦"
        XCTAssertEqual(family.count, 1)
        let cleaned = clean("a\u{1B}" + family + "\u{202E}b")
        XCTAssertEqual(scalars(cleaned), scalars("a" + family + "b"))
        XCTAssertEqual(cleaned.count, 3)
    }

    func testAPersianWordKeepsItsNonJoiner() {
        let word = "می\u{200C}خواهم"
        XCTAssertEqual(scalars(clean("\u{202E}" + word + "\n")), scalars(word))
    }

    /// Scalars are dropped whole and nothing is cut: a letter keeps every one of its marks,
    /// a flag its two halves, a keycap its three scalars.
    func testAClusterIsNeverSplit() {
        for cluster in ["e\u{301}\u{323}", "🇺🇦", "1\u{FE0F}\u{20E3}", "👍🏽", "क\u{94D}\u{200D}ष"] {
            XCTAssertEqual(cluster.count, 1, cluster)
            let cleaned = clean("\u{9B}" + cluster + "\u{200B}" + cluster + "\t")
            XCTAssertEqual(scalars(cleaned), scalars(cluster + cluster), cluster)
            XCTAssertEqual(cleaned.count, 2, cluster)
        }
    }

    /// A subdivision flag is a black flag and tag characters. The tags are format
    /// characters and go, and the flag that is left is one character.
    func testATagSequenceLeavesItsBlackFlag() {
        let scotland = "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        XCTAssertEqual(scalars(clean(scotland)), scalars("🏴"))
    }

    // MARK: - Design 5: no length cap, and no trap

    /// One character of 100 000 combining marks comes back whole: no cap is introduced
    /// here. The rule is one pass over the scalars, so its time grows with the length.
    func testACharacterOfAHundredThousandMarksComesBackWhole() {
        let giant = "e" + String(repeating: "\u{301}", count: 100_000)
        let started = Date()
        let cleaned = clean("\u{1B}" + giant + "\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(cleaned.unicodeScalars.count, 100_001)
        XCTAssertTrue(cleaned.unicodeScalars.elementsEqual(giant.unicodeScalars))
    }

    func testAMegabyteOfHostileTextIsCleanedInOnePass() {
        let piece = "word \u{1B}[0m\u{9B}\u{202E}\n"
        let megabyte = String(repeating: piece, count: 80_000)
        XCTAssertGreaterThan(megabyte.utf8.count, 1_000_000)
        let started = Date()
        let cleaned = clean(megabyte)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "linear: a megabyte is milliseconds")
        XCTAssertEqual(TerminalStringFixture.removed(in: cleaned), [])
        // Compared as a flag: a megabyte in a failure message helps nobody.
        XCTAssertTrue(cleaned == Array(repeating: "word [0m", count: 80_000).joined(separator: " "),
                      "each line break left one space and the last one none")
    }

    /// Twice the input, about twice the time, never four times: the rule holds no step
    /// that looks back over what it has kept.
    func testTheTimeGrowsWithTheLengthAndNotWithItsSquare() {
        func seconds(_ count: Int) -> TimeInterval {
            let text = String(repeating: "word\u{301} \u{1B}[0m\n", count: count)
            var best = TimeInterval.infinity
            for _ in 0..<3 {
                let started = Date()
                _ = clean(text)
                best = min(best, Date().timeIntervalSince(started))
            }
            return best
        }
        let small = seconds(200_000)
        let large = seconds(1_600_000)
        XCTAssertLessThan(large, max(small, 0.001) * 8 * 4, "eight times the input took \(large / small) times as long")
    }

    // MARK: - Design 6: the status line drops the same scalars

    private func model(_ name: String) throws -> String? {
        let payload = try JSONSerialization.data(withJSONObject: ["model": ["display_name": name]])
        return StatusLineInput.parse(payload).model
    }

    /// The model name drops a scalar exactly when `TerminalString.isInvisible` says so:
    /// one of every kind, the joiners, and what neither removes.
    func testTheModelNameDropsWhatIsInvisibleAndNothingElse() throws {
        let others: [Unicode.Scalar] = ["\u{200C}", "\u{200D}", "é", "\u{301}", "\u{00A0}", "-", "5", "漢"]
        let samples = TerminalStringFixture.kinds.flatMap { Array($0.text.unicodeScalars) } + others
        for scalar in samples {
            var view = String.UnicodeScalarView()
            view.append("x")
            view.append(scalar)
            view.append("y")
            let expected = TerminalString.isInvisible(scalar) ? "xy" : String(view)
            XCTAssertEqual(try model(String(view)).map(scalars), scalars(expected),
                           "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    }

    /// The model name's own outcome is not this rule's: a name with nothing to show is no
    /// name (nil, and the line's fallback), never the unseen mark, and a line break in it
    /// leaves no space.
    func testTheModelNameKeepsItsOwnOutcomeAndCaps() throws {
        XCTAssertNil(try model("\u{1B}\u{200B}"))
        XCTAssertNil(try model("\u{200D}"))
        XCTAssertEqual(try model("Opus\n5"), "Opus5")
        XCTAssertEqual(try model(String(repeating: "x", count: 200))?.count, StatusLineInput.maximumModelNameLength)
        XCTAssertEqual(StatusLineInput.maximumModelNameLength, 64)
        XCTAssertEqual(StatusLineInput.maximumModelNameScalars, 256)
    }
}
