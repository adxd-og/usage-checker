import XCTest
@testable import Omelette

/// `Main.dc.html` and `Popover-Claude.dc.html` set a figure's unit smaller and in
/// secondary: "57" + "%", "11m" + " left".
final class OMFigureTests: XCTestCase {
    func testAPercentagesSignIsItsUnit() {
        XCTAssertEqual(OMFigure.split("57%"), OMFigure.Parts(value: "57", unit: "%"))
        XCTAssertEqual(OMFigure.split("100%"), OMFigure.Parts(value: "100", unit: "%"))
    }

    func testATimeLeftKeepsItsSpaceBeforeLeft() {
        XCTAssertEqual(OMFigure.split("11m left"), OMFigure.Parts(value: "11m", unit: " left"))
        XCTAssertEqual(OMFigure.split("6d 9h left"), OMFigure.Parts(value: "6d 9h", unit: " left"))
    }

    func testAFigureWithoutAUnitIsWhole() {
        XCTAssertEqual(OMFigure.split("12:50"), OMFigure.Parts(value: "12:50", unit: nil))
        XCTAssertEqual(OMFigure.split("$2,975.97"), OMFigure.Parts(value: "$2,975.97", unit: nil))
        XCTAssertEqual(OMFigure.split("—"), OMFigure.Parts(value: "—", unit: nil))
    }

    func testAUnitAloneIsNotSplitIntoNothing() {
        XCTAssertEqual(OMFigure.split("%"), OMFigure.Parts(value: "%", unit: nil))
        XCTAssertEqual(OMFigure.split(""), OMFigure.Parts(value: "", unit: nil))
    }
}
