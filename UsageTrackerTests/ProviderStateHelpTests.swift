import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3, decisions moved out of views: the sign-in recovery
/// help, with no direct installation check in the view (review finding 23). Each
/// provider's state gets its way out; whether Antigravity is installed comes in.
final class ProviderStateHelpTests: XCTestCase {
    private func help(_ service: ServiceSnapshot, binary: Bool = true, installed: Bool = true) -> ProviderStateHelp? {
        ProviderStateHelp.help(for: service, claudeBinaryFound: binary, claudeNote: nil, antigravityInstalled: installed)
    }

    func testASignedOutClaudeGetsItsSignInHelp() throws {
        let claude = Fixture.snapshot(id: "claude", state: .notSignedIn)
        let result = try XCTUnwrap(help(claude))
        XCTAssertEqual(result.message, ClaudeSignInCopy.signInHelp)
        XCTAssertEqual(result.claude?.recovery, .signIn)
        XCTAssertNil(result.command)
    }

    func testAClaudeWhoseSignInCannotBeReadIsSentToAdvanced() {
        var claude = Fixture.snapshot(id: "claude", state: .notSignedIn)
        claude.signedOutReason = .denied
        XCTAssertEqual(help(claude)?.claude?.recovery, .keychainAccess)
    }

    func testALiveOrFailingProviderWithoutAWayOutHasNoHelp() {
        XCTAssertNil(help(Fixture.snapshot(id: "claude")))
        XCTAssertNil(help(Fixture.snapshot(id: "grok", state: .error)))
        XCTAssertNil(help(Fixture.snapshot(id: "antigravity")))
    }

    func testASignedOutCodexCopiesTheLoginCommand() {
        XCTAssertEqual(
            help(Fixture.snapshot(id: "codex", state: .notSignedIn)),
            ProviderStateHelp(
                message: "Codex reports limits only for ChatGPT sign-in (API-key auth doesn't expose them).",
                command: "codex logout && codex login"
            )
        )
    }

    func testAnInstalledAntigravityOffersToOpenTheApp() {
        let closed = Fixture.snapshot(id: "antigravity", state: .notRunning)
        XCTAssertEqual(
            help(closed, installed: true),
            ProviderStateHelp(
                message: "Antigravity shares quotas only while the app, `agy` CLI, or IDE is running.",
                appPath: "/Applications/Antigravity.app"
            )
        )
    }

    func testWithoutTheAppAntigravitysHelpCopiesTheCLICommand() {
        let closed = Fixture.snapshot(id: "antigravity", state: .notRunning)
        XCTAssertEqual(help(closed, installed: false)?.command, "agy")
        XCTAssertNil(help(closed, installed: false)?.appPath)
    }

    func testASignedOutGrokLinksToItsUsagePage() {
        XCTAssertEqual(
            help(Fixture.snapshot(id: "grok", state: .notSignedIn)),
            ProviderStateHelp(
                message: "Sign into the Grok CLI, then refresh. Credits reset with your xAI billing period.",
                command: "grok login",
                linkTitle: "Open grok.com usage",
                linkURL: URL(string: "https://grok.com/?_s=usage")
            )
        )
    }

    func testTheHelpsButtonsSayCopyAndOpenAntigravity() {
        XCTAssertEqual(ProviderStateHelp.copyButton, "Copy")
        XCTAssertEqual(ProviderStateHelp.openAntigravityButton, "Open Antigravity")
    }
}
