import Security
import XCTest
@testable import Omelette

/// Spec 2026-10-25 § Design › Package 2, Omelette's own token cache (ruling 1a): the keychain
/// item 3.2 and earlier kept a token copy in is deleted once, on the first launch of the new
/// build, silently — a locked keychain would answer a delete with its password panel, so it
/// waits for a later launch. The delete itself is passed in; nothing here touches a keychain.
final class ClaudeLegacyTokenCopyTests: XCTestCase {
    private final class Deletes { var count = 0 }

    func testAnEarlierLaunchThatRemovedItMeansNothingIsAsked() {
        let deletes = Deletes()
        let result = ClaudeCredentialsCache.removeLegacyItem(alreadyDone: true, keychainUnlocked: true) {
            deletes.count += 1
            return errSecSuccess
        }
        XCTAssertEqual(result, .alreadyDone)
        XCTAssertEqual(deletes.count, 0)
    }

    func testALockedKeychainWaitsForTheNextLaunch() {
        let deletes = Deletes()
        let result = ClaudeCredentialsCache.removeLegacyItem(alreadyDone: false, keychainUnlocked: false) {
            deletes.count += 1
            return errSecSuccess
        }
        XCTAssertEqual(result, .deferred)
        XCTAssertEqual(deletes.count, 0, "a delete on a locked keychain raises its password panel")
    }

    func testADeletedItemIsDone() {
        XCTAssertEqual(ClaudeCredentialsCache.removeLegacyItem(alreadyDone: false, keychainUnlocked: true) { errSecSuccess }, .done)
    }

    func testAnItemThatIsNotThereIsDone() {
        XCTAssertEqual(ClaudeCredentialsCache.removeLegacyItem(alreadyDone: false, keychainUnlocked: true) { errSecItemNotFound }, .done)
    }

    func testARefusedDeleteIsTriedAgainNextLaunch() {
        XCTAssertEqual(
            ClaudeCredentialsCache.removeLegacyItem(alreadyDone: false, keychainUnlocked: true) { errSecAuthFailed },
            .failed(errSecAuthFailed)
        )
        XCTAssertEqual(ClaudeCredentialsCache.legacyService, "com.usagetracker.app.claude-oauth-cache")
        XCTAssertEqual(ClaudeCredentialsCache.legacyAccount, "claude-oauth")
    }
}
