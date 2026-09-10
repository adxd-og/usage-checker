import XCTest
@testable import Omelette

/// Issue #4: which build am I running, and where does this thing live? Both answers
/// belonged only to Settings. `AppVersion` is the one rule the popover footer and the
/// dashboard sidebar draw their label and their link from.
final class AppVersionTests: XCTestCase {
    func testTheLabelIsTheAppNameAndTheMarketingVersion() {
        XCTAssertEqual(AppVersion.label(version: "2.4.1", build: "39"), "Omelette 2.4.1")
    }

    /// Settings shows "2.4.1 (39)" because that row is for a bug report. A footer
    /// label is for recognition: the build number is noise there.
    func testTheLabelNeverCarriesTheBuildNumber() {
        let label = AppVersion.label(version: "2.4.1", build: "39")
        XCTAssertFalse(label.contains("39"))
        XCTAssertFalse(label.contains("("))
    }

    func testAMissingVersionLeavesJustTheName() {
        XCTAssertEqual(AppVersion.label(version: nil, build: "39"), "Omelette")
        XCTAssertEqual(AppVersion.label(version: "", build: "39"), "Omelette")
        XCTAssertEqual(AppVersion.label(version: "   ", build: nil), "Omelette")
    }

    func testAMissingBuildChangesNothing() {
        XCTAssertEqual(AppVersion.label(version: "2.4.1", build: nil), "Omelette 2.4.1")
    }

    func testTheLinkPointsAtThePublicRepository() {
        XCTAssertEqual(AppVersion.githubURL.absoluteString, "https://github.com/adxd-og/usage-checker")
    }

    /// `current` reads the running bundle, so the assertion is about its shape, not
    /// about a version number that changes with every release.
    func testTheCurrentLabelReadsTheRunningBundle() {
        XCTAssertTrue(AppVersion.current.hasPrefix("Omelette"), AppVersion.current)
        XCTAssertFalse(AppVersion.current.contains("("), AppVersion.current)
    }

    func testTheSettingsRowNamesTheSiteAndTheLinkOpensTheRepository() {
        XCTAssertEqual(AppVersion.githubLabel, "GitHub")
        XCTAssertEqual(AppVersion.githubURL.host, "github.com")
        XCTAssertEqual(AppVersion.githubURL.path, "/adxd-og/usage-checker")
        XCTAssertFalse(AppVersion.githubHelp.isEmpty)
    }
}
