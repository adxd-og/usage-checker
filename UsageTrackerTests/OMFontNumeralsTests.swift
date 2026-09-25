import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Tokens: "Numerals: SF Pro Rounded, tabular."
/// Every 3.0 figure takes its font from one function, so a column of numbers lines up
/// and a ticking value does not shift sideways.
final class OMFontNumeralsTests: XCTestCase {
    func testFiguresAreSFProRoundedWithTabularDigits() {
        XCTAssertEqual(
            OMFont.numerals(size: 13, weight: .semibold),
            Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
        )
    }

    func testRoundedWithProportionalDigitsIsNotEnough() {
        XCTAssertNotEqual(
            OMFont.numerals(size: 13, weight: .semibold),
            Font.system(size: 13, weight: .semibold, design: .rounded)
        )
    }

    func testSizeAndWeightAreTheCallers() {
        XCTAssertEqual(
            OMFont.numerals(size: 22, weight: .bold),
            Font.system(size: 22, weight: .bold, design: .rounded).monospacedDigit()
        )
    }
}
