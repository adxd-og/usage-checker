import XCTest
@testable import Omelette

/// Spec 2026-10-25 § Design › Package 2, Omelette's own token cache (ruling 1a, 2026-10-27):
/// the copy of Claude Code's token lives in memory for the process's life — never in a
/// keychain item or a file, so a second cache, like the next launch, starts empty.
final class ClaudeCredentialsCacheTests: XCTestCase {
    private func oauth(_ token: String, expiresAt: Double) -> ClaudeCredentials.OAuth {
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r","expiresAt":\(expiresAt),
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    func testASavedTokenIsReadBack() {
        let cache = ClaudeCredentialsCache()
        XCTAssertNil(cache.load())
        cache.save(oauth("first", expiresAt: 1_800_000_000_000))
        XCTAssertEqual(cache.load()?.accessToken, "first")
    }

    func testTheLastSaveWins() {
        let cache = ClaudeCredentialsCache()
        cache.save(oauth("first", expiresAt: 1_800_000_000_000))
        cache.save(oauth("second", expiresAt: 1_800_000_360_000))
        XCTAssertEqual(cache.load()?.accessToken, "second")
        XCTAssertEqual(cache.load()?.expiresAt, 1_800_000_360_000)
    }

    func testAnotherCacheStartsEmptyWhateverThisOneHolds() {
        let first = ClaudeCredentialsCache()
        first.save(oauth("first", expiresAt: 1_800_000_000_000))
        XCTAssertNil(ClaudeCredentialsCache().load(), "nothing is written anywhere a new process would find it")
    }
}
