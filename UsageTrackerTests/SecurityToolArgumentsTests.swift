import XCTest
@testable import Omelette

/// The read Brioche delegates to `/usr/bin/security` (spec 2026-11-10 Mistral provider
/// § Credential: the same delegation as Claude's): Claude Code's item by its service alone, as
/// before, and the item of a service that keeps one per account — vibe's `MISTRAL_API_KEY` — by
/// its account too. Only the arguments: no test runs the tool or touches the keychain.
final class SecurityToolArgumentsTests: XCTestCase {
    func testClaudeCodesItemIsStillReadByItsServiceAlone() {
        XCTAssertEqual(
            ClaudeKeychainReader.securityArguments(service: ClaudeKeychainReader.service),
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
    }

    func testAnAccountNamesTheOneItemOfAServiceThatHoldsSeveral() {
        XCTAssertEqual(
            ClaudeKeychainReader.securityArguments(service: "ai.mistral.vibe", account: "MISTRAL_API_KEY"),
            ["find-generic-password", "-s", "ai.mistral.vibe", "-a", "MISTRAL_API_KEY", "-w"]
        )
    }
}
