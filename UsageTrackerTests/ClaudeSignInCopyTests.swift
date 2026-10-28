import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: every word about
/// Claude's sign-in comes from one rule, and a signed-out Claude offers the way out its reason
/// calls for — Sign in for not signed in and expired (the install link when no Claude Code is
/// on this Mac), keychain access for denied, nothing for unreadable — with and without its
/// last numbers kept beside it.
final class ClaudeSignInCopyTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_793_100_000)
    private let now = Date(timeIntervalSince1970: 1_793_100_600)

    /// A signed-out Claude as the app shows it: fresh from the provider, or merged with the
    /// numbers of an earlier healthy poll.
    private func signedOut(_ reason: SignedOutReason?, keptNumbers: Bool) -> ServiceSnapshot {
        let fresh = ServiceSnapshot.notSignedIn(reason: reason, message: "Signed out.", at: now)
        guard keptNumbers else { return fresh }
        let previous = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 40, kind: .session)],
            at: earlier
        )
        return AppState.mergingPoll(
            previous: UsageSnapshot(services: [previous], fetchedAt: earlier, isStale: false, lastError: nil),
            next: UsageSnapshot(services: [fresh], fetchedAt: now, isStale: false, lastError: nil)
        ).services[0]
    }

    // MARK: - The way out

    func testEachReasonOffersItsWayOutWithAndWithoutKeptNumbers() {
        let expected: [(SignedOutReason, Bool, ClaudeRecovery)] = [
            (.notFound, true, .signIn), (.notFound, false, .install),
            (.expired, true, .signIn), (.expired, false, .install),
            (.denied, true, .keychainAccess), (.denied, false, .keychainAccess),
            (.unreadable, true, .noAction), (.unreadable, false, .noAction),
        ]
        for (reason, binaryFound, recovery) in expected {
            for kept in [false, true] {
                let service = signedOut(reason, keptNumbers: kept)
                XCTAssertEqual(service.isRetained, kept, "\(reason)")
                XCTAssertEqual(
                    ClaudeSignInCopy.recovery(for: service, binaryFound: binaryFound), recovery,
                    "\(reason), binary \(binaryFound), kept \(kept)"
                )
            }
        }
    }

    func testASignedOutClaudeWithNoReasonCountsAsNotSignedIn() {
        XCTAssertEqual(ClaudeSignInCopy.recovery(for: signedOut(nil, keptNumbers: false), binaryFound: true), .signIn)
    }

    func testOnlyASignedOutClaudeOffersAnything() {
        XCTAssertNil(ClaudeSignInCopy.recovery(for: nil, binaryFound: true), "Claude switched off")
        XCTAssertNil(ClaudeSignInCopy.recovery(for: Fixture.snapshot(id: "claude", at: now), binaryFound: true))
        XCTAssertNil(ClaudeSignInCopy.recovery(for: Fixture.snapshot(id: "claude", state: .error, at: now), binaryFound: true))
        XCTAssertNil(ClaudeSignInCopy.recovery(for: Fixture.snapshot(id: "codex", state: .notSignedIn, at: now), binaryFound: true))
    }

    // MARK: - The popover help

    func testTheHelpSaysWhatTheWayOutIs() throws {
        func message(_ reason: SignedOutReason, binaryFound: Bool = true) throws -> String {
            try XCTUnwrap(ClaudeSignInCopy.help(for: signedOut(reason, keptNumbers: false), binaryFound: binaryFound, note: nil)).message
        }
        XCTAssertEqual(try message(.notFound), ClaudeSignInCopy.signInHelp)
        XCTAssertEqual(try message(.expired), ClaudeSignInCopy.expiredHelp)
        XCTAssertEqual(try message(.expired, binaryFound: false), ClaudeSignInCopy.installHelp)
        XCTAssertEqual(try message(.denied), ClaudeSignInCopy.deniedHelp)
        XCTAssertEqual(try message(.unreadable), ClaudeSignInCopy.unreadableHelp)
    }

    func testTheLineAfterAClickShowsWhereAClickCanStart() throws {
        let pending = try XCTUnwrap(ClaudeSignInCopy.help(for: signedOut(.notFound, keptNumbers: true), binaryFound: true, note: .pending))
        XCTAssertEqual(pending.recovery, .signIn)
        XCTAssertEqual(pending.note, ClaudeSignInCopy.pendingLine)
        XCTAssertFalse(pending.noteIsFailure)

        let failed = try XCTUnwrap(ClaudeSignInCopy.help(
            for: signedOut(.notFound, keptNumbers: false), binaryFound: false, note: .failed(ClaudeSignInCopy.binaryMissing)
        ))
        XCTAssertEqual(failed.recovery, .install)
        XCTAssertEqual(failed.note, "Sign in did not start: Claude Code was not found on this Mac.")
        XCTAssertTrue(failed.noteIsFailure)

        let denied = try XCTUnwrap(ClaudeSignInCopy.help(for: signedOut(.denied, keptNumbers: false), binaryFound: true, note: .pending))
        XCTAssertNil(denied.note, "no Sign in was offered there")
    }

    // MARK: - The words

    func testTheWordsAreThese() {
        XCTAssertEqual(ClaudeSignInCopy.notFoundMessage, "Not signed in to Claude Code on this Mac.")
        XCTAssertEqual(ClaudeSignInCopy.expiredMessage, "Claude Code's sign-in has expired.")
        XCTAssertEqual(ClaudeSignInCopy.deniedMessage, "Omelette needs your permission to read Claude Code's sign-in.")
        XCTAssertEqual(ClaudeSignInCopy.signInButton, "Sign in")
        XCTAssertEqual(ClaudeSignInCopy.installLinkTitle, "Install Claude Code")
        XCTAssertEqual(ClaudeSignInCopy.advancedButton, "Open Settings › Advanced")
        XCTAssertEqual(ClaudeSignInCopy.pendingLine, "Finish signing in in Terminal. Omelette checks again when you come back.")
        XCTAssertEqual(
            ClaudeSignInCopy.launchFailure(ClaudeSignInCopy.terminalMissing),
            "Sign in did not start: Terminal is not on this Mac."
        )
        XCTAssertEqual(ClaudeSignInCopy.installURL.absoluteString, "https://code.claude.com/docs/en/setup")
    }

    func testNothingAsksForACommandOrMentionsTheWidget() {
        let all = [
            ClaudeSignInCopy.notFoundMessage, ClaudeSignInCopy.expiredMessage, ClaudeSignInCopy.deniedMessage,
            ClaudeSignInCopy.signInHelp, ClaudeSignInCopy.expiredHelp, ClaudeSignInCopy.deniedHelp,
            ClaudeSignInCopy.unreadableHelp, ClaudeSignInCopy.installHelp, ClaudeSignInCopy.pendingLine,
            ClaudeSignInCopy.terminalMissing, ClaudeSignInCopy.binaryMissing,
        ]
        for text in all {
            XCTAssertFalse(text.contains("claude login"), text)
            XCTAssertFalse(text.contains("`"), text)
            XCTAssertFalse(text.lowercased().contains("widget"), text)
        }
    }

    func testKeychainAccessPointsAtTheAdvancedTab() {
        XCTAssertTrue(ClaudeSignInCopy.deniedHelp.contains("Settings › \(SettingsTab.advanced.rawValue)"))
        XCTAssertTrue(ClaudeSignInCopy.advancedButton.hasSuffix(SettingsTab.advanced.rawValue))
    }

    func testTheKeychainErrorsSayTheSameWords() {
        XCTAssertEqual(ClaudeKeychainError.notFound.errorDescription, ClaudeSignInCopy.notFoundMessage)
        XCTAssertEqual(ClaudeKeychainError.interactionRequired.errorDescription, ClaudeSignInCopy.deniedMessage)
    }
}
