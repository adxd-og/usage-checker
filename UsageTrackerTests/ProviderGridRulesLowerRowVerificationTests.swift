import XCTest
@testable import Omelette

/// Verification of the lower row without an agents card (notch-island spec 2026-10-29 § 3.3,
/// owner 2026-10-30): keep awake and the cost tile above it span the row, and the width
/// handed to `KeepAwakeCardLayout` is the interior of that full width.
@MainActor
final class ProviderGridRulesLowerRowVerificationTests: XCTestCase {
    private let widths: [CGFloat] = [560, 640, 720]

    func testTheRowIsAlwaysTheGridsWidthWithOrWithoutAnAgentsCard() {
        for body in widths {
            for habitat in [false, true] {
                let columns = ProviderGridRules.columns(bodyWidth: body, showsHabitat: habitat)
                let split = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: true)
                let spans = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: false)
                let label = "body \(body) habitat \(habitat)"

                XCTAssertEqual(split.agentsWidth, columns.half, label)
                XCTAssertEqual(split.otherWidth, columns.half, label)
                XCTAssertEqual(
                    (split.agentsWidth ?? 0) + ProviderGridRules.gap + split.otherWidth, columns.right,
                    "\(label): two halves and the gap are the whole grid"
                )
                XCTAssertNil(spans.agentsWidth, label)
                XCTAssertEqual(spans.otherWidth, columns.right, "\(label): keep awake takes the row")
                XCTAssertGreaterThan(spans.otherWidth, split.otherWidth, label)
            }
        }
    }

    func testKeepAwakeInteriorIsTheCardWidthLessItsPaddingOnBothSides() {
        for body in widths {
            let columns = ProviderGridRules.columns(bodyWidth: body, showsHabitat: true)
            for hasCard in [false, true] {
                let row = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: hasCard)
                XCTAssertEqual(row.keepAwakeInterior, row.otherWidth - 2 * KeepAwakeCardLayout.padding)
            }
            // The half-width interior is still what the old `cardInterior` answered.
            XCTAssertEqual(
                ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: true).keepAwakeInterior,
                columns.cardInterior
            )
        }
    }

    func testWithoutAnAgentsCardKeepAwakesControlsShareOneRowAtEveryIslandWidth() {
        let measured = KeepAwakeCardLayout.measuredWidths()
        // The combinations `IslandPresentationRules` can produce: 560 never has the habitat.
        for (body, habitat) in [(CGFloat(560), false), (640, false), (640, true), (720, false), (720, true)] {
            do {
                let columns = ProviderGridRules.columns(bodyWidth: body, showsHabitat: habitat)
                let interior = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: false).keepAwakeInterior
                XCTAssertEqual(
                    KeepAwakeCardLayout.arrangement(interiorWidth: interior, widths: measured), .oneRow,
                    "body \(body) habitat \(habitat): interior \(interior) vs one row \(KeepAwakeCardLayout.oneRowWidth(measured))"
                )
                XCTAssertTrue(KeepAwakeCardLayout.linesFit(interiorWidth: interior, widths: measured))
            }
        }
    }

    func testBesideTheAgentsCardKeepAwakeStillStacksAtTheHabitatWidthsAndEveryLineFits() {
        // The island's two-column widths (640 and 720 with the habitat): the half is narrow, so
        // the fields take one row and the buttons the next, as before this change.
        let measured = KeepAwakeCardLayout.measuredWidths()
        for body in [CGFloat(640), 720] {
            let columns = ProviderGridRules.columns(bodyWidth: body, showsHabitat: true)
            let interior = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: true).keepAwakeInterior
            XCTAssertEqual(
                KeepAwakeCardLayout.arrangement(interiorWidth: interior, widths: measured), .twoRows,
                "body \(body): interior \(interior) vs one row \(KeepAwakeCardLayout.oneRowWidth(measured))"
            )
            XCTAssertTrue(KeepAwakeCardLayout.linesFit(interiorWidth: interior, widths: measured), "body \(body)")
        }
    }
}
