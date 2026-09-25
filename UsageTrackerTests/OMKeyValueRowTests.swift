import XCTest
@testable import Omelette

/// `Popover-Claude.dc.html`'s weekly rows: a 12.5 pt semibold label, the value as a
/// rounded 14 pt figure with a 9 pt "%", a 6 pt bar 7 pt below. Other rows keep their
/// value as a caption.
final class OMKeyValueRowTests: XCTestCase {
    @MainActor
    func testARowIsACaptionUnlessItAsksForAFigure() {
        XCTAssertEqual(OMKeyValueRow(label: "Extra usage", value: "$12.40 / $50").valueStyle, .caption)
        XCTAssertEqual(OMKeyValueRow(label: "All models", value: "41%", valueStyle: .figure).valueStyle, .figure)
    }

    func testTheRowIsTheMockupsRow() {
        XCTAssertEqual(OMKeyValueRow.labelSize, 12.5)
        XCTAssertEqual(OMKeyValueRow.captionSize, 12.5)
        XCTAssertEqual(OMKeyValueRow.figureSize, 14)
        XCTAssertEqual(OMKeyValueRow.figureUnitSize, 9)
        XCTAssertEqual(OMKeyValueRow.barHeight, 6)
        XCTAssertEqual(OMKeyValueRow.barSpacing, 7)
    }

    func testTheBarUnderARowIsTheSlimBar() {
        XCTAssertEqual(OMKeyValueRow.barStyle, .slim)
    }

    func testVoiceOverReadsLabelAndValueUnlessTheCallerSaysMore() {
        XCTAssertEqual(OMKeyValueRow.spokenText(label: "Fable", value: "47%", override: nil), "Fable, 47%")
        XCTAssertEqual(
            OMKeyValueRow.spokenText(label: "Fable", value: "47%", override: "Fable only · resets Thu 12:59, 47 percent used"),
            "Fable only · resets Thu 12:59, 47 percent used"
        )
    }
}
