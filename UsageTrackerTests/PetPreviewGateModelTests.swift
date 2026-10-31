import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7: "The previews animate only while the Settings window is visible
/// (same gate)": `PetAnimationGate` with the picker's window as the surface.
@MainActor
final class PetPreviewGateModelTests: XCTestCase {
    func testItStartsOff() {
        XCTAssertFalse(PetPreviewGateModel().animates)
    }

    func testItAnimatesOnlyWithThePickerShownInAVisibleWindow() {
        let model = PetPreviewGateModel()
        model.setShown(true)
        XCTAssertFalse(model.animates, "the window not known to be visible yet")
        model.setWindowVisible(true)
        XCTAssertTrue(model.animates)
        model.setWindowVisible(false)
        XCTAssertFalse(model.animates, "closed, covered, another Space")
        model.setWindowVisible(true)
        model.setShown(false)
        XCTAssertFalse(model.animates, "another tab")
    }

    func testSleepTheLockAndReduceMotionEachStopIt() {
        let model = PetPreviewGateModel()
        model.setShown(true)
        model.setWindowVisible(true)
        model.setDisplayAwake(false)
        XCTAssertFalse(model.animates)
        model.setDisplayAwake(true)
        model.setScreenLocked(true)
        XCTAssertFalse(model.animates)
        model.setScreenLocked(false)
        model.setReduceMotion(true)
        XCTAssertFalse(model.animates)
        model.setReduceMotion(false)
        XCTAssertTrue(model.animates)
    }

    func testOnlyAChangeIsPublished() {
        let model = PetPreviewGateModel()
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        model.setShown(true)
        model.setShown(true)
        model.setReduceMotion(false)
        model.setDisplayAwake(true)
        XCTAssertEqual(changes, 1)
        watch.cancel()
    }
}
