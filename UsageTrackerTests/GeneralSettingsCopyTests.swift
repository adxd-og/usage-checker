import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "General: Launch at login, popover shortcut,
/// refresh interval, updates, version, GitHub", in `Settings-General.dc.html`'s words,
/// less the popover shortcut (removed on the owner's decision, 2026-09-26).
/// § Decisions: bracketed placeholders are the live values.
final class GeneralSettingsCopyTests: XCTestCase {
    func testTheVersionRowKeepsTheBuildABugReportNeeds() {
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: "2.7.1", build: "38"), "Brioche 2.7.1 (38)")
    }

    func testWithoutABuildTheVersionRowIsTheLabel() {
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: "2.7.1", build: nil), "Brioche 2.7.1")
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: " 2.7.1 ", build: "  "), "Brioche 2.7.1")
    }

    func testWithoutAVersionTheRowIsTheAppsName() {
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: nil, build: "38"), "Brioche")
    }

    func testTheGitHubRowNamesTheRepository() {
        XCTAssertEqual(GeneralSettingsCopy.githubTitle, "GitHub")
        XCTAssertEqual(GeneralSettingsCopy.githubLinkText, "adxd-og/usage-checker")
    }

    func testTheRowsReadAsTheMockup() {
        XCTAssertEqual(GeneralSettingsCopy.startupHeader, "Startup")
        XCTAssertEqual(GeneralSettingsCopy.launchAtLoginTitle, "Launch at login")
        XCTAssertEqual(GeneralSettingsCopy.refreshHeader, "Refresh")
        XCTAssertEqual(GeneralSettingsCopy.refreshTitle, "Update every")
        XCTAssertEqual(GeneralSettingsCopy.refreshFooter, "Faster is closer to real time but can hit rate limits.")
        XCTAssertEqual(GeneralSettingsCopy.updatesHeader, "Updates")
        XCTAssertEqual(GeneralSettingsCopy.autoCheckTitle, "Check for updates automatically")
        XCTAssertEqual(GeneralSettingsCopy.checkNowButton, "Check now")
    }

    /// Keep-awake spec 2026-10-26 § UI: "Settings › General, section "Keep awake": the floor
    /// switch"; § Behaviour: "End below 25 % on battery".
    func testTheKeepAwakeSectionReadsAsTheSpec() {
        XCTAssertEqual(GeneralSettingsCopy.keepAwakeHeader, "Keep awake")
        XCTAssertEqual(GeneralSettingsCopy.keepAwakeFloorTitle, "End below 25 % on battery")
        XCTAssertEqual(GeneralSettingsCopy.keepAwakeFooter, "Keep awake with the lid closed ends on time even when Brioche is not running, and never resumes after a restart.")
    }

    /// Notch-island spec 2026-10-29 § 3.7: the switch that brings the status item back.
    func testTheMenuBarIconSectionNamesItsSwitch() {
        XCTAssertEqual(GeneralSettingsCopy.menuBarIconHeader, "Menu bar icon")
        XCTAssertEqual(GeneralSettingsCopy.showInMenuBarTitle, "Show in menu bar")
    }

    /// Spec 2026-11-03 § P4: the switch above Show in menu bar that turns the virtual notch off.
    func testTheVirtualNotchSwitchSaysWhatItDoesAndWhatOffBringsBack() {
        XCTAssertEqual(GeneralSettingsCopy.virtualNotchTitle, "Island on displays without a notch")
        XCTAssertEqual(
            GeneralSettingsCopy.virtualNotchCaption,
            "A black pill in the middle of the menu bar opens Brioche. Off: the menu bar icon opens it there, as before 4.1; with a notched display attached, turn on Show in menu bar."
        )
    }
}
