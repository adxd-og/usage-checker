import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: Claude Code's
/// keychain item can hold other entries (`mcpOAuth`) and no `claudeAiOauth` after a sign-out.
/// Such an item is "not signed in", with the Sign in button, never "unreadable"; a sign-in
/// that is there but malformed still is. The rule is `ClaudeCredentials.decodeSignIn`, which
/// every decode site of Claude Code's credentials goes through.
final class ClaudeSignInDecodeTests: XCTestCase {
    func testAnItemWithoutAClaudeSignInIsNotFound() throws {
        XCTAssertNil(try ClaudeCredentials.decodeSignIn(from: Data(#"{"mcpOAuth":{"x":{}}}"#.utf8)))
    }

    func testAMalformedSignInIsStillUnreadable() {
        XCTAssertThrowsError(try ClaudeCredentials.decodeSignIn(from: Data(#"{"claudeAiOauth":{"accessToken":1}}"#.utf8)))
    }

    func testASignInDecodes() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"sk-ant-ort01-test",
         "expiresAt":1793100000000,"scopes":["user:inference","user:profile"],
         "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
         "mcpOAuth":{"x":{}}}
        """
        let oauth = try XCTUnwrap(try ClaudeCredentials.decodeSignIn(from: Data(json.utf8)))
        XCTAssertEqual(oauth.accessToken, "sk-ant-oat01-test")
        XCTAssertEqual(oauth.refreshToken, "sk-ant-ort01-test")
        XCTAssertEqual(oauth.expiresAt, 1_793_100_000_000)
        XCTAssertEqual(oauth.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(oauth.subscriptionType, "max")
        XCTAssertEqual(oauth.rateLimitTier, "default_claude_max_20x")
    }
}
