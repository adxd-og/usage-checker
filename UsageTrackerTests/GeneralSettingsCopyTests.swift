import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "General: Launch at login, popover shortcut,
/// refresh interval, updates, version, GitHub", in `Settings-General.dc.html`'s words,
/// less the popover shortcut (removed on the owner's decision, 2026-09-26).
/// § Decisions: bracketed placeholders are the live values.
final class GeneralSettingsCopyTests: XCTestCase {
    func testTheVersionRowKeepsTheBuildABugReportNeeds() {
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: "2.7.1", build: "38"), "Omelette 2.7.1 (38)")
    }

    func testWithoutABuildTheVersionRowIsTheLabel() {
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: "2.7.1", build: nil), "Omelette 2.7.1")
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: " 2.7.1 ", build: "  "), "Omelette 2.7.1")
    }

    func testWithoutAVersionTheRowIsTheAppsName() {
        XCTAssertEqual(GeneralSettingsCopy.versionTitle(version: nil, build: "38"), "Omelette")
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
}
