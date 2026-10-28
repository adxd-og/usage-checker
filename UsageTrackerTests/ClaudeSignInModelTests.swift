import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: the button shows
/// while there may be a `claude` to run — before the first look, and when one was found; with no
/// binary at all the install link takes its place.
final class ClaudeSignInModelTests: XCTestCase {
    func testBeforeTheFirstLookTheButtonShows() {
        XCTAssertTrue(ClaudeSignInModel.binaryFound(binary: nil, hasLooked: false), "a click looks again first")
    }

    func testAFoundBinaryShowsTheButton() {
        XCTAssertTrue(ClaudeSignInModel.binaryFound(binary: "/opt/homebrew/bin/claude", hasLooked: true))
    }

    func testNoBinaryAfterALookIsTheInstallLink() {
        XCTAssertFalse(ClaudeSignInModel.binaryFound(binary: nil, hasLooked: true))
    }
}
