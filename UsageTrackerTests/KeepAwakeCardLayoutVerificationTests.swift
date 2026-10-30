import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.3 (Keep-awake card) and § 3.9
/// (`KeepAwakeCardLayout`): one row or two for supplied widths, at the interiors the grid
/// gives at 560, 640 and 720 with and without the habitat. No test reads the machine's fonts
/// (CLAUDE.md: machine inputs are injected).
final class KeepAwakeCardLayoutVerificationTests: XCTestCase {
    private let widths = KeepAwakeCardLayout.Widths(units: [8, 8, 22], apply: 68, cancel: 74, spinner: 16, approval: 139)

    private func interior(_ body: CGFloat, _ habitat: Bool) -> CGFloat {
        ProviderGridRules.columns(bodyWidth: body, showsHabitat: habitat).cardInterior
    }

    func testTheCardIsTwoRowsAtEveryIslandWidthTheGridCanGive() {
        for (body, habitat) in [(640, true), (720, true), (560, false), (640, false), (720, false)] as [(CGFloat, Bool)] {
            XCTAssertEqual(
                KeepAwakeCardLayout.arrangement(interiorWidth: interior(body, habitat), widths: widths), .twoRows,
                "\(body) habitat \(habitat): \(interior(body, habitat)) < 359"
            )
        }
    }

    func testAWidthEqualToTheLinesWidthFitsAndAPointLessDoesNot() {
        // The fields row is 177 and the buttons row 174; the approval button 139.
        XCTAssertTrue(KeepAwakeCardLayout.linesFit(interiorWidth: 177, widths: widths))
        XCTAssertFalse(KeepAwakeCardLayout.linesFit(interiorWidth: 176.99, widths: widths))
    }

    func testTheWidestLineDecidesWhetherTheCardFits() {
        let wideButtons = KeepAwakeCardLayout.Widths(units: [8, 8, 22], apply: 90, cancel: 90, spinner: 16, approval: 139)
        XCTAssertEqual(KeepAwakeCardLayout.buttonsWidth(wideButtons), 212)
        XCTAssertFalse(KeepAwakeCardLayout.linesFit(interiorWidth: 192, widths: wideButtons), "buttons are the widest")
        XCTAssertTrue(KeepAwakeCardLayout.linesFit(interiorWidth: 212, widths: wideButtons))

        let wideApproval = KeepAwakeCardLayout.Widths(units: [8, 8, 22], apply: 68, cancel: 74, spinner: 16, approval: 200)
        XCTAssertFalse(KeepAwakeCardLayout.linesFit(interiorWidth: 192, widths: wideApproval), "the approval button is the widest")
        XCTAssertTrue(KeepAwakeCardLayout.linesFit(interiorWidth: 200, widths: wideApproval))
    }

    func testTheOneRowWidthIsTheFieldsPlusTheButtonsPlusTheGapBetweenThem() {
        XCTAssertEqual(
            KeepAwakeCardLayout.oneRowWidth(widths),
            KeepAwakeCardLayout.fieldsWidth(widths) + KeepAwakeCardLayout.spacing + KeepAwakeCardLayout.buttonsWidth(widths)
        )
        // Cancel and the spinner are counted though they show only sometimes: dropping either
        // would let the row grow when Cancel appears while armed.
        let withoutCancel = KeepAwakeCardLayout.Widths(units: [8, 8, 22], apply: 68, cancel: 0, spinner: 16, approval: 139)
        XCTAssertLessThan(KeepAwakeCardLayout.oneRowWidth(withoutCancel), KeepAwakeCardLayout.oneRowWidth(widths))
    }

    func testWiderUnitWordsWidenTheFieldsRowOneToOne() {
        let wider = KeepAwakeCardLayout.Widths(units: [20, 20, 40], apply: 68, cancel: 74, spinner: 16, approval: 139)
        XCTAssertEqual(KeepAwakeCardLayout.fieldsWidth(wider) - KeepAwakeCardLayout.fieldsWidth(widths), 12 + 12 + 18)
    }

    func testTheCardIsOneRowAsSoonAsTheInteriorReachesTheOneRowWidthWhateverTheWords() {
        let short = KeepAwakeCardLayout.Widths(units: [6, 6, 16], apply: 40, cancel: 40, spinner: 16, approval: 100)
        let need = KeepAwakeCardLayout.oneRowWidth(short)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: need, widths: short), .oneRow)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: need - 0.5, widths: short), .twoRows)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: 10_000, widths: widths), .oneRow)
        XCTAssertEqual(KeepAwakeCardLayout.arrangement(interiorWidth: 0, widths: widths), .twoRows)
    }
}
