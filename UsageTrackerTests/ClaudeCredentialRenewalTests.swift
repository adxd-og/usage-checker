import XCTest
@testable import Omelette

/// After a 401 the provider re-reads Claude Code's credential sources with no "beat
/// this" floor — the token that just failed may still be the newest thing on disk. That
/// makes the acceptance rule the only thing standing between the cache and a token
/// that's even older than the dead one.
final class ClaudeCredentialRenewalTests: XCTestCase {
    private func oauth(token: String, expiresAt: Double) -> ClaudeCredentials.OAuth {
        // Decoded rather than constructed: the app has no test-only initializer, and
        // this is the shape Claude Code actually writes.
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    private let expiredAt: Double = 1_800_000_000_000

    func testANewerDifferentTokenIsAccepted() {
        XCTAssertTrue(ClaudeOAuthProvider.isUsableRenewal(
            oauth(token: "fresh", expiresAt: expiredAt + 3_600_000),
            after: oauth(token: "dead", expiresAt: expiredAt)
        ))
    }

    func testAnOlderTokenIsRefused() {
        // A stale `~/.claude/.credentials.json` next to a newer cached copy. Swapping it
        // in would replace the dead token with a deader one and blank the menu bar.
        XCTAssertFalse(ClaudeOAuthProvider.isUsableRenewal(
            oauth(token: "ancient", expiresAt: expiredAt - 3_600_000),
            after: oauth(token: "dead", expiresAt: expiredAt)
        ))
    }

    func testTheSameTokenIsRefusedHoweverFreshItLooks() {
        // Same string, so it is the token that just came back 401 — retrying it would
        // spend another request to be told the same thing.
        XCTAssertFalse(ClaudeOAuthProvider.isUsableRenewal(
            oauth(token: "dead", expiresAt: expiredAt + 3_600_000),
            after: oauth(token: "dead", expiresAt: expiredAt)
        ))
    }

    func testARotationInTheSameMillisecondStillCounts() {
        // `>=`, not `>`: Claude Code can mint a replacement carrying the identical
        // expiry, and refusing it would strand the app on the dead one.
        XCTAssertTrue(ClaudeOAuthProvider.isUsableRenewal(
            oauth(token: "fresh", expiresAt: expiredAt),
            after: oauth(token: "dead", expiresAt: expiredAt)
        ))
    }
}
