import XCTest
@testable import Omelette

/// How the Limits tab spells its figures: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab ("≈ 4.2 %", "Shares
/// under 0.1 % read '< 0.1 %'", "1 % ≈ $62 · 130 M tokens") and the ruling that Outside
/// this Mac is whole points on Claude.
final class LimitsCopyTests: XCTestCase {
    func testAShareReadsOneDecimalAfterAnApproximateSign() {
        XCTAssertEqual(LimitsCopy.share(21.9), "≈ 21.9 %")
        XCTAssertEqual(LimitsCopy.share(1.04), "≈ 1.0 %")
        XCTAssertEqual(LimitsCopy.share(0.1), "≈ 0.1 %")
    }

    func testAShareUnderATenthOfAPointReadsLessThanATenth() {
        XCTAssertEqual(LimitsCopy.share(0.099), "< 0.1 %")
        XCTAssertEqual(LimitsCopy.share(0), "< 0.1 %", "a chat whose half hours moved nothing still spent quota")
        XCTAssertEqual(LimitsCopy.share(0.1 - 1e-12), "≈ 0.1 %", "a sum of fractions a hair under a tenth is a tenth")
    }

    func testAWholeShareHasNoDecimal() {
        XCTAssertEqual(LimitsCopy.wholeShare(2), "≈ 2 %")
        XCTAssertEqual(LimitsCopy.wholeShare(3.000_000_000_4), "≈ 3 %")
    }

    func testDollarsDropTheirCentsFromTenDollars() {
        XCTAssertEqual(LimitsCopy.dollars(1_358.4), "$1,358")
        XCTAssertEqual(LimitsCopy.dollars(62.2), "$62")
        XCTAssertEqual(LimitsCopy.dollars(10), "$10")
        XCTAssertEqual(LimitsCopy.dollars(6.2), "$6.20", "a whole dollar would hide a small figure")
        XCTAssertEqual(LimitsCopy.dollars(0.42), "$0.42")
    }

    func testTokensCarryTheirUnit() {
        XCTAssertEqual(LimitsCopy.tokens(130_000_000), "130 M")
        XCTAssertEqual(LimitsCopy.tokens(9_500_000), "9.5 M")
        XCTAssertEqual(LimitsCopy.tokens(2_500_000_000), "2.5 B")
        XCTAssertEqual(LimitsCopy.tokens(84_000), "84 k")
        XCTAssertEqual(LimitsCopy.tokens(512), "512")
    }
}
