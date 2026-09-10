import XCTest
@testable import Omelette

/// The one place in the codebase allowed to write `100 - x`. Spec
/// `2026-09-10-remaining-mode-design.md` § "One rule".
final class PercentDisplayTests: XCTestCase {
    func testUsedModeDrawsTheNumberItIsGiven() {
        XCTAssertEqual(PercentDisplay.shown(37, mode: .used), 37)
        XCTAssertEqual(PercentDisplay.percentText(37, mode: .used), "37%")
    }

    func testRemainingModeDrawsTheComplement() {
        XCTAssertEqual(PercentDisplay.shown(37, mode: .remaining), 63)
        XCTAssertEqual(PercentDisplay.percentText(37, mode: .remaining), "63%")
    }

    func testAWindowPastItsLimitHasNothingLeftRatherThanLessThanNothing() {
        // A spend limit reports 137%. "−37% left" is not a thing to put on a ring.
        XCTAssertEqual(PercentDisplay.shown(137, mode: .used), 100)
        XCTAssertEqual(PercentDisplay.shown(137, mode: .remaining), 0)
        XCTAssertEqual(PercentDisplay.percentText(137, mode: .remaining), "0%")
    }

    func testANegativeReadingIsAnUntouchedWindow() {
        XCTAssertEqual(PercentDisplay.shown(-3, mode: .used), 0)
        XCTAssertEqual(PercentDisplay.shown(-3, mode: .remaining), 100)
    }

    func testEachHalfRoundsOnItsOwnValue() {
        // 37.5 used rounds to 38; 62.5 left rounds to 63. Two correct roundings of
        // two different numbers — pinned so nobody "fixes" one into the other.
        XCTAssertEqual(PercentDisplay.percentText(37.5, mode: .used), "38%")
        XCTAssertEqual(PercentDisplay.percentText(37.5, mode: .remaining), "63%")
    }

    func testTheMenuBarGetsDigitsWithNoPercentSign() {
        XCTAssertEqual(PercentDisplay.bareNumber(37, mode: .used), "37")
        XCTAssertEqual(PercentDisplay.bareNumber(37, mode: .remaining), "63")
    }

    func testTheSuffixIsTheWordThatSpellsTheNumberOut() {
        XCTAssertEqual(PercentDisplay.suffix(mode: .used), "used")
        XCTAssertEqual(PercentDisplay.suffix(mode: .remaining), "left")
    }

    func testOnlyRemainingSpellsItselfOutInPlainText() {
        // "42%" has meant used since 1.0 and scripts grep for it; a bare "58%" in
        // remaining mode would be a lie, so that half carries the word.
        XCTAssertEqual(PercentDisplay.percentPhrase(42, mode: .used), "42%")
        XCTAssertEqual(PercentDisplay.percentPhrase(42, mode: .remaining), "58% left")
    }

    func testVoiceOverAlwaysHearsTheWord() {
        XCTAssertEqual(PercentDisplay.spoken(42, mode: .used), "42 percent used")
        XCTAssertEqual(PercentDisplay.spoken(42, mode: .remaining), "58 percent left")
    }

    func testThePaceMarkerMirrorsSoTheComparisonSurvives() {
        XCTAssertEqual(PercentDisplay.pace(0.25, mode: .used), 0.25)
        XCTAssertEqual(PercentDisplay.pace(0.25, mode: .remaining), 0.75)
    }

    func testNoResetTimeMeansNoPaceMarkerInEitherMode() {
        XCTAssertNil(PercentDisplay.pace(nil, mode: .used))
        XCTAssertNil(PercentDisplay.pace(nil, mode: .remaining))
    }

    func testAPaceFractionOutsideTheWindowIsClamped() {
        XCTAssertEqual(PercentDisplay.pace(1.4, mode: .used), 1)
        XCTAssertEqual(PercentDisplay.pace(1.4, mode: .remaining), 0)
        XCTAssertEqual(PercentDisplay.pace(-0.2, mode: .remaining), 1)
    }

    func testTheModeIsCodableSoItCanRideInAFile() throws {
        let data = try JSONEncoder().encode(PercentDisplay.Mode.remaining)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"remaining\"")
        XCTAssertEqual(try JSONDecoder().decode(PercentDisplay.Mode.self, from: data), .remaining)
    }
}
