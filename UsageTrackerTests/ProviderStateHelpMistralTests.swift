import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § States: a Mistral with no key or a refused key gets the
/// way back to a key vibe keeps (the command to copy is `vibe`); no usage access gets help that
/// names the permission; any other failure, and a live Mistral, get none.
final class ProviderStateHelpMistralTests: XCTestCase {
    private func help(_ service: ServiceSnapshot) -> ProviderStateHelp? {
        ProviderStateHelp.help(for: service, claudeBinaryFound: true, claudeNote: nil, antigravityInstalled: true)
    }

    private func mistral(_ state: ServiceState, message: String? = nil, reason: SignedOutReason? = nil) -> ServiceSnapshot {
        var service = Fixture.snapshot(id: "mistral", displayName: "Mistral", plan: "Pro", state: state, stateMessage: message)
        service.signedOutReason = reason
        return service
    }

    func testNoKeyAnywhereSendsTheUserToVibe() {
        XCTAssertEqual(
            help(mistral(.notSignedIn, message: MistralCopy.notSignedInMessage, reason: .notFound)),
            ProviderStateHelp(message: MistralCopy.notSignedInHelp, command: "vibe")
        )
    }

    func testARefusedKeySaysToSignInToVibeAgain() {
        XCTAssertEqual(
            help(mistral(.notSignedIn, message: MistralCopy.signedOutMessage, reason: .expired)),
            ProviderStateHelp(message: MistralCopy.signedOutHelp, command: "vibe")
        )
    }

    func testNoUsageAccessNamesThePermission() throws {
        let result = try XCTUnwrap(help(mistral(.error, message: MistralCopy.noUsageAccessMessage)))
        XCTAssertEqual(result, ProviderStateHelp(message: MistralCopy.noUsageAccessHelp))
        XCTAssertTrue(result.message.contains("see_org_inference_usage"))
    }

    func testAnyOtherFailureAndALiveMistralHaveNoHelp() {
        XCTAssertNil(help(mistral(.error, message: "HTTP 503 (service unavailable)")))
        XCTAssertNil(help(mistral(.error, message: MistralCopy.rateLimitedMessage)))
        XCTAssertNil(help(mistral(.ok)))
    }
}
