import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7: "palette (a grid of the four animals in their palettes). The
/// previews animate only while the Settings window is visible (same gate) and only the selected one
/// loops."
final class PetPickerRulesTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()
    private let duck = PetChoice(animal: "duck", palette: "white")

    private func columns(_ selected: PetChoice = .standard) -> [PetPickerColumn] {
        PetPickerRules.columns(library: Self.shipped, selected: selected)
    }

    func testTheGridIsTheFourAnimalsInTheirThreePalettes() {
        XCTAssertEqual(columns().map(\.animal), ["cat", "duck", "dog", "raccoon"])
        XCTAssertEqual(columns().map(\.name), ["Cat", "Duck", "Dog", "Raccoon"])
        XCTAssertEqual(columns()[2].cells.map(\.choice.palette), ["tan", "black-white", "cream"])
        XCTAssertEqual(columns()[2].cells.map(\.paletteName), ["Tan", "Black-white", "Cream"])
    }

    func testOnlyTheChosenCellIsSelected() {
        let selected = columns(duck).flatMap(\.cells).filter(\.isSelected)
        XCTAssertEqual(selected.map(\.choice), [duck])
    }

    func testOnlyTheSelectedOneLoopsAndOnlyWhileTheGateIsOn() {
        let cells = columns(duck).flatMap(\.cells)
        XCTAssertEqual(cells.filter { PetPickerRules.loops($0, gateOn: true, petOn: true) }.map(\.choice), [duck])
        XCTAssertEqual(cells.filter { PetPickerRules.loops($0, gateOn: false, petOn: true) }, [])
    }

    func testNothingLoopsWithThePetOff() {
        let cells = columns(duck).flatMap(\.cells)
        XCTAssertEqual(cells.filter { PetPickerRules.loops($0, gateOn: true, petOn: false) }, [])
    }

    func testThePreviewWalksItsFramesAtTheAnimationsRate() {
        let idle = PetAnimation(frames: ["idle_1", "idle_2"], fps: 2)
        XCTAssertEqual(PetPickerRules.frameName(of: idle, at: Date(timeIntervalSinceReferenceDate: 0)), "idle_1")
        XCTAssertEqual(PetPickerRules.frameName(of: idle, at: Date(timeIntervalSinceReferenceDate: 0.5)), "idle_2")
        XCTAssertEqual(PetPickerRules.frameName(of: idle, at: Date(timeIntervalSinceReferenceDate: 1)), "idle_1")
        XCTAssertEqual(PetPickerRules.frameName(of: idle, at: Date(timeIntervalSinceReferenceDate: 1.75)), "idle_2")
    }

    func testEveryCellSaysWhatItIsToVoiceOver() {
        XCTAssertEqual(columns()[0].cells[0].accessibilityLabel, "Cat, ginger")
        XCTAssertEqual(columns()[2].cells[1].accessibilityLabel, "Dog, black-white")
    }

    func testAnEmptyLibraryHasAnEmptyGrid() {
        XCTAssertEqual(PetPickerRules.columns(library: .empty, selected: .standard), [])
    }
}
