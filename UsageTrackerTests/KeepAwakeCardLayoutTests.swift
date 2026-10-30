import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (Keep-awake card), § 3.9 (`KeepAwakeCardLayout`) and
/// review finding 6: the 3.x controls do not fit a ≈ 192 pt card at 640. Under the one-row
/// width — measured with Apply, Cancel and the spinner showing at once, the widest the
/// buttons get — the fields take one row and the buttons the next. Tested at 640 and 720
/// with supplied widths only: no test reads the machine's fonts (plan ruling R16).
final class KeepAwakeCardLayoutTests: XCTestCase {
    /// d, h and min at 12.5 pt; Apply, Cancel and Open Login Items at 12.5 pt semibold
    /// plus the small capsule's 16 + 16, as the system font set them on 2026-10-30.
    private let widths = KeepAwakeCardLayout.Widths(units: [8, 8, 22], apply: 68, cancel: 74, spinner: 16, approval: 139)

    private func interior(_ bodyWidth: CGFloat, habitat: Bool) -> CGFloat {
        ProviderGridRules.columns(bodyWidth: bodyWidth, showsHabitat: habitat).cardInterior
    }

    func testTheFieldsRowIsThreeFieldsWithTheirUnits() {
        // 3 × (38 + 3) + 8 + 8 + 22 + 2 × 8
        XCTAssertEqual(KeepAwakeCardLayout.fieldsWidth(widths), 177)
    }

    func testTheButtonsAreMeasuredWithCancelAndTheSpinnerShowing() {
        // 68 + 8 + 74 + 8 + 16
        XCTAssertEqual(KeepAwakeCardLayout.buttonsWidth(widths), 174)
        XCTAssertEqual(KeepAwakeCardLayout.oneRowWidth(widths), 359)
    }

    func testAt640TheCardTakesTwoRows() {
        XCTAssertEqual(interior(640, habitat: true), 192)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: 192, widths: widths), .twoRows)
    }

    func testAt720TheCardStillTakesTwoRows() {
        XCTAssertEqual(interior(720, habitat: true), 232)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: 232, widths: widths), .twoRows)
    }

    func testOneRowOnlyFromTheOneRowWidthOn() {
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: 359, widths: widths), .oneRow)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: 358.5, widths: widths), .twoRows)
    }

    func testEveryLineFitsTheCardAtEveryIslandWidth() {
        let islands: [(CGFloat, Bool)] = [(640, true), (720, true), (560, false), (640, false), (720, false)]
        for (body, habitat) in islands {
            XCTAssertTrue(
                KeepAwakeCardLayout.linesFit(interiorWidth: interior(body, habitat: habitat), widths: widths),
                "\(body) pt, habitat \(habitat)"
            )
        }
        // A point under the 177 pt fields row and the card would clip. (The 3.x 44 pt fields
        // needed 3 × (44 + 3) + 38 + 16 = 195 > 192.)
        XCTAssertFalse(KeepAwakeCardLayout.linesFit(interiorWidth: 176, widths: widths))
    }

    func testTheNaturalHeightIsThePaddingTheStatusTheGapAndTheControls() {
        // 14 + 60 + 12 + 64 + 14
        XCTAssertEqual(KeepAwakeCardLayout.naturalHeight(top: 60, controls: 64), 164)
    }
}
