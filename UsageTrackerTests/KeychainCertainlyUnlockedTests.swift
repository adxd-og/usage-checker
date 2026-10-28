import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, ruling 2b: Omelette starts
/// Claude Code, runs `/usr/bin/security` or deletes its old item only on a login keychain that is
/// certainly unlocked. "Could not tell" is not unlocked: a locked keychain answers those with a
/// password panel no flag suppresses.
final class KeychainCertainlyUnlockedTests: XCTestCase {
    func testOnlyAnUnlockedKeychainIsCertainlyUnlocked() {
        XCTAssertTrue(KeychainNoUI.isCertainlyUnlocked(.unlocked))
    }

    func testALockedKeychainIsNot() {
        XCTAssertFalse(KeychainNoUI.isCertainlyUnlocked(.locked))
    }

    func testAKeychainWhoseStateCannotBeReadCountsAsLocked() {
        XCTAssertFalse(KeychainNoUI.isCertainlyUnlocked(.unknown))
    }
}
