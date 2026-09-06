import CodexBarCore
import XCTest
@testable import Omelette

/// CodexBarCore tells the user to "Enable CodexBar's Antigravity provider" — advice
/// for an app they are not running. The state message has to name Omelette's own
/// Settings instead, and it has to keep doing so when upstream renames the case.
final class GeminiErrorCopyTests: XCTestCase {
    private let ourAdvice = "Sign in to the Gemini CLI again, or enable Antigravity in Settings → Providers."

    func testTheConsumerTierShutdownGetsOurWording() {
        XCTAssertEqual(
            GeminiErrorCopy.stateMessage(for: GeminiStatusProbeError.consumerTierDeprecated),
            ourAdvice
        )
        XCTAssertEqual(GeminiErrorCopy.antigravityAdvice, ourAdvice)
    }

    func testUpstreamsOwnTextMentionsTheAppWeAreReplacing() {
        // The reason this rule exists, asserted against the real string so a bump that
        // rewrites it is visible here rather than in a screenshot.
        XCTAssertTrue(
            GeminiConsumerTierMigration.deprecationError.contains("CodexBar's Antigravity provider"),
            GeminiConsumerTierMigration.deprecationError
        )
    }

    func testAnyErrorWhoseTextPointsAtAntigravityGetsOurWording() {
        // Forward cover for the case the upstream bump adds
        // (`oauthCredentialsUnavailableWithAntigravity`): it carries the same advice,
        // so it gets the same replacement without this file naming it.
        struct Upstream: LocalizedError {
            var errorDescription: String? {
                "Gemini OAuth credentials are unavailable. Enable CodexBar's Antigravity provider, then refresh."
            }
        }
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: Upstream()), ourAdvice)
    }

    func testEveryOtherGeminiErrorKeepsItsOwnMessage() {
        XCTAssertEqual(
            GeminiErrorCopy.stateMessage(for: GeminiStatusProbeError.notLoggedIn),
            GeminiStatusProbeError.notLoggedIn.localizedDescription
        )
        XCTAssertEqual(
            GeminiErrorCopy.stateMessage(for: GeminiStatusProbeError.unsupportedAuthType("API key")),
            GeminiStatusProbeError.unsupportedAuthType("API key").localizedDescription
        )
        XCTAssertEqual(
            GeminiErrorCopy.stateMessage(for: GeminiStatusProbeError.timedOut),
            GeminiStatusProbeError.timedOut.localizedDescription
        )
    }

    func testAnUnrelatedErrorIsPassedThroughUntouched() {
        let network = URLError(.notConnectedToInternet)
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: network), network.localizedDescription)
    }
}
