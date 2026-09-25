import XCTest
@testable import Omelette

/// Owner's check of P7 (2026-09-25), Settings › General › "Open the popover": recording a
/// shortcut needs a visible way out. KeyboardShortcuts cancels on Esc and clears on Delete
/// while it records, and shows its own × once a shortcut is set, but says none of it. The
/// row's caption says it for as long as the recorder is recording.
final class GeneralSettingsShortcutTests: XCTestCase {
    func testAtRestTheCaptionIsTheMockups() {
        XCTAssertEqual(
            GeneralSettingsCopy.shortcutRowCaption(isRecording: false),
            "Works from any app. Unset by default."
        )
        XCTAssertEqual(GeneralSettingsCopy.shortcutRowCaption(isRecording: false), GeneralSettingsCopy.shortcutCaption)
    }

    func testWhileRecordingTheCaptionSaysHowToCancel() {
        XCTAssertEqual(
            GeneralSettingsCopy.shortcutRowCaption(isRecording: true),
            "Press the keys. Esc cancels, Delete clears."
        )
    }

    func testTheRecorderAnnouncingItsStartMeansRecording() {
        XCTAssertTrue(GeneralSettingsCopy.isRecording(["isActive": true]))
    }

    func testTheRecorderAnnouncingItsEndMeansNotRecording() {
        XCTAssertFalse(GeneralSettingsCopy.isRecording(["isActive": false]))
    }

    /// An announcement without the flag, or with one of another type, never leaves the
    /// caption saying Esc cancels after recording ended.
    func testAnAnnouncementWithoutAFlagMeansNotRecording() {
        XCTAssertFalse(GeneralSettingsCopy.isRecording(nil))
        XCTAssertFalse(GeneralSettingsCopy.isRecording([:]))
        XCTAssertFalse(GeneralSettingsCopy.isRecording(["isActive": "yes"]))
    }

    /// The name KeyboardShortcuts 2.x posts on the default centre when its recorder starts
    /// and stops (`RecorderCocoa`, `recorderActiveStatusDidChange`). The library keeps the
    /// constant internal, so the row names it itself.
    func testTheRowListensUnderTheLibrarysName() {
        XCTAssertEqual(
            GeneralSettingsCopy.recorderActivityNotification.rawValue,
            "KeyboardShortcuts_recorderActiveStatusDidChange"
        )
    }
}
