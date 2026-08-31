import XCTest
@testable import Omelette

/// The delegated read exists because a keychain ACL trusts binaries, not apps: renaming
/// or re-signing this one drops it off `Claude Code-credentials`' trust list, and its own
/// silent read can then only ever fail. What must hold in every environment is the
/// preflight — no trust, no subprocess — because an untrusted `security` would raise from
/// a background poll the very panel the silent-keychain work removed.
final class KeychainDelegatedReadTests: XCTestCase {
    /// A service no keychain has an item for, so the answer can't depend on the machine.
    private let absentService = "com.usagetracker.tests.absent-service"

    func testTrustPreflightSaysNoForAnItemThatDoesNotExist() {
        XCTAssertFalse(KeychainNoUI.aclTrusts(path: "/usr/bin/security", service: absentService))
    }

    func testTrustPreflightSaysNoForABinaryNoAclNames() {
        // /bin/ls is on no trust list anywhere; a true here would mean the ACL walk is
        // matching something other than the path it was handed.
        XCTAssertFalse(
            KeychainNoUI.aclTrusts(path: "/bin/ls", service: ClaudeKeychainReader.service)
        )
    }

    func testAbsentItemIsReportedAsMissingRatherThanHanging() {
        // Also covers the subprocess timeout: a hang here fails the suite instead of
        // silently stalling a poll.
        let done = expectation(description: "delegated read returns")
        DispatchQueue.global().async {
            XCTAssertNil(ClaudeKeychainReader.readViaSecurityTool(for: self.absentService))
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
