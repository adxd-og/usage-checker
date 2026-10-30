import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (Keep-awake card) and plan ruling R15: the card's
/// words go through `KeepAwakeCopy`. An empty duration field shows 0, the number Apply
/// reads from it.
final class KeepAwakeFieldCopyTests: XCTestCase {
    func testAnEmptyFieldShowsTheZeroApplyReads() {
        XCTAssertEqual(KeepAwakeCopy.fieldPlaceholder, "0")
        XCTAssertEqual(KeepAwakeCopy.fieldNumber(""), 0)
    }
}
