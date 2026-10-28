import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: the Settings row
/// offers a Sign in button beside Claude's switch while Claude is on and signed out (the install
/// link when no Claude Code is on this Mac), and the line a click left under its status. The
/// keychain cases keep their button in Settings › Advanced.
final class ProvidersClaudeSignInTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    private func row(_ id: String) throws -> ProvidersSettingsCopy.Provider {
        try XCTUnwrap(ProvidersSettingsCopy.listed.first { $0.id == id })
    }

    private func signedOut(_ reason: SignedOutReason) -> ServiceSnapshot {
        .notSignedIn(reason: reason, message: "Signed out.", at: now)
    }

    func testClaudesRowOffersSignInWhileNotSignedInOrExpired() throws {
        let claude = try row(ProvidersSettingsCopy.claudeID)
        for reason in [SignedOutReason.notFound, .expired] {
            XCTAssertEqual(
                ProvidersSettingsCopy.claudeAction(for: claude, service: signedOut(reason), isEnabled: true, binaryFound: true),
                .signIn, "\(reason)"
            )
            XCTAssertEqual(
                ProvidersSettingsCopy.claudeAction(for: claude, service: signedOut(reason), isEnabled: true, binaryFound: false),
                .install, "\(reason)"
            )
        }
    }

    func testTheKeychainCasesOfferNothingOnTheRow() throws {
        let claude = try row(ProvidersSettingsCopy.claudeID)
        XCTAssertNil(ProvidersSettingsCopy.claudeAction(for: claude, service: signedOut(.denied), isEnabled: true, binaryFound: true))
        XCTAssertNil(ProvidersSettingsCopy.claudeAction(for: claude, service: signedOut(.unreadable), isEnabled: true, binaryFound: true))
    }

    func testNothingIsOfferedWithClaudeOffOrReadingFine() throws {
        let claude = try row(ProvidersSettingsCopy.claudeID)
        XCTAssertNil(ProvidersSettingsCopy.claudeAction(for: claude, service: signedOut(.notFound), isEnabled: false, binaryFound: true))
        XCTAssertNil(ProvidersSettingsCopy.claudeAction(for: claude, service: nil, isEnabled: true, binaryFound: true))
        XCTAssertNil(ProvidersSettingsCopy.claudeAction(
            for: claude, service: Fixture.snapshot(id: "claude", at: now), isEnabled: true, binaryFound: true
        ))
    }

    func testNoOtherRowOffersIt() throws {
        let codex = try row(ProvidersSettingsCopy.codexID)
        XCTAssertNil(ProvidersSettingsCopy.claudeAction(
            for: codex, service: Fixture.snapshot(id: "codex", state: .notSignedIn, at: now), isEnabled: true, binaryFound: true
        ))
    }

    func testTheLineAfterAClick() {
        XCTAssertEqual(
            ProvidersSettingsCopy.claudeNote(.pending, action: .signIn),
            SettingsCaption(text: ClaudeSignInCopy.pendingLine, token: .secondary)
        )
        XCTAssertEqual(
            ProvidersSettingsCopy.claudeNote(.failed(ClaudeSignInCopy.terminalMissing), action: .signIn),
            SettingsCaption(text: "Sign in did not start: Terminal is not on this Mac.", token: .warning)
        )
        XCTAssertNil(ProvidersSettingsCopy.claudeNote(.pending, action: nil), "no button, no line")
        XCTAssertNil(ProvidersSettingsCopy.claudeNote(nil, action: .signIn))
    }
}
