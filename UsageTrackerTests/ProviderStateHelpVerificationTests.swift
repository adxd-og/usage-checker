import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.3 (decisions moved out of views: sign-in
/// recovery help with no direct installation check in the view) and plan Task 6: the whole
/// provider x state matrix, so no provider gains or loses a way out by the move, and
/// Claude's way out follows `ClaudeSignInCopy`.
final class ProviderStateHelpVerificationTests: XCTestCase {
    private let states: [ServiceState] = [.ok, .notSignedIn, .notRunning, .error]

    private func help(
        _ service: ServiceSnapshot, binary: Bool = true, note: ClaudeSignInNote? = nil, installed: Bool = true
    ) -> ProviderStateHelp? {
        ProviderStateHelp.help(for: service, claudeBinaryFound: binary, claudeNote: note, antigravityInstalled: installed)
    }

    func testOnlyTheDocumentedProviderAndStateCombinationsHaveAWayOut() {
        let expected: [String: Set<ServiceState>] = [
            "claude": [.notSignedIn],
            "codex": [.notSignedIn],
            "antigravity": [.notSignedIn, .notRunning, .error],
            "grok": [.notSignedIn],
            "anthropic-admin": [],
            "unknown": [],
        ]
        for (id, withHelp) in expected {
            for state in states {
                let result = help(Fixture.snapshot(id: id, state: state))
                XCTAssertEqual(result != nil, withHelp.contains(state), "\(id) \(state)")
            }
        }
    }

    func testAntigravityOffersExactlyOneOfTheAppAndTheCommandInEveryUnhealthyState() throws {
        for state in [ServiceState.notSignedIn, .notRunning, .error] {
            let installed = try XCTUnwrap(help(Fixture.snapshot(id: "antigravity", state: state), installed: true))
            XCTAssertEqual(installed.appPath, ProviderStateHelp.antigravityAppPath, "\(state)")
            XCTAssertNil(installed.command, "\(state)")
            let missing = try XCTUnwrap(help(Fixture.snapshot(id: "antigravity", state: state), installed: false))
            XCTAssertNil(missing.appPath, "\(state)")
            XCTAssertEqual(missing.command, "agy", "\(state)")
            XCTAssertEqual(installed.message, missing.message)
        }
    }

    func testOtherProvidersHelpDoesNotDependOnAntigravityOrClaudeInputs() {
        for installed in [true, false] {
            for binary in [true, false] {
                let codex = help(Fixture.snapshot(id: "codex", state: .notSignedIn), binary: binary, installed: installed)
                XCTAssertEqual(codex?.command, "codex logout && codex login")
                XCTAssertNil(codex?.appPath)
                XCTAssertNil(codex?.claude)
                let grok = help(Fixture.snapshot(id: "grok", state: .notSignedIn), binary: binary, installed: installed)
                XCTAssertEqual(grok?.command, "grok login")
                XCTAssertEqual(grok?.linkURL, URL(string: "https://grok.com/?_s=usage"))
            }
        }
    }

    func testClaudesWayOutIsClaudeSignInCopysForEverySignedOutReasonAndBinary() {
        let reasons: [SignedOutReason?] = [nil, .notFound, .expired, .denied, .unreadable]
        for reason in reasons {
            for binary in [true, false] {
                var claude = Fixture.snapshot(id: "claude", state: .notSignedIn)
                claude.signedOutReason = reason
                let direct = ClaudeSignInCopy.help(for: claude, binaryFound: binary, note: nil)
                let result = help(claude, binary: binary)
                XCTAssertEqual(result?.claude, direct, "\(String(describing: reason)) binary \(binary)")
                XCTAssertEqual(result?.message, direct?.message)
                XCTAssertNil(result?.command, "Claude copies no command")
            }
        }
    }

    func testAClickNoteReachesClaudesHelpOnlyWhereAClickCanStart() {
        let failed = ClaudeSignInNote.failed("no terminal")
        let signedOut = Fixture.snapshot(id: "claude", state: .notSignedIn)
        XCTAssertEqual(help(signedOut, note: failed)?.claude?.note, ClaudeSignInCopy.launchFailure("no terminal"))
        XCTAssertEqual(help(signedOut, note: failed)?.claude?.noteIsFailure, true)
        var denied = signedOut
        denied.signedOutReason = .denied
        XCTAssertNil(help(denied, note: failed)?.claude?.note, "no click starts from the keychain-access help")
    }

    func testAWindowlessLiveClaudeAndALiveCodexNeverGetHelp() {
        XCTAssertNil(help(Fixture.snapshot(id: "claude", state: .ok)))
        XCTAssertNil(help(Fixture.snapshot(id: "codex", state: .ok)))
        XCTAssertNil(help(Fixture.snapshot(id: "codex", state: .error)))
        XCTAssertNil(help(Fixture.snapshot(id: "grok", state: .notRunning)))
    }
}
