import CodexBarCore
import XCTest
@testable import Omelette

/// Independent verification of `GeminiErrorCopy.stateMessage`, pinning the exact
/// case-sensitivity of its text-matching fallback — the spec's attack list asks
/// "an error whose description merely contains 'antigravity' lowercase (should it
/// match? read the rule and pin the actual behaviour)". The rule is
/// `localizedCaseInsensitiveContains("Antigravity provider")`, so it is
/// case-insensitive on the whole phrase — this file pins that literally, plus the
/// substring's exact boundaries.
final class GeminiErrorCopyVerificationTests: XCTestCase {
    private let ourAdvice = "Sign in to the Gemini CLI again, or enable Antigravity in Settings → Providers."

    func testAllLowercaseAntigravityProviderStillMatches() {
        struct Upstream: LocalizedError {
            var errorDescription: String? { "please enable antigravity provider to continue" }
        }
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: Upstream()), ourAdvice,
                       "localizedCaseInsensitiveContains is case-insensitive on the whole phrase, lowercase included")
    }

    func testAllCapsAntigravityProviderStillMatches() {
        struct Upstream: LocalizedError {
            var errorDescription: String? { "ANTIGRAVITY PROVIDER must be enabled" }
        }
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: Upstream()), ourAdvice)
    }

    func testAntigravityAloneWithoutTheWordProviderDoesNotMatch() {
        // The matched phrase is "Antigravity provider" as a whole, not just the brand
        // name — an error that names Antigravity without calling it "the provider"
        // is not necessarily CodexBar's specific advice and keeps its own text.
        struct Upstream: LocalizedError {
            var errorDescription: String? { "Please open Antigravity and sign in again." }
        }
        let upstream = Upstream()
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: upstream), upstream.localizedDescription)
    }

    func testProviderAloneWithoutAntigravityDoesNotMatch() {
        struct Upstream: LocalizedError {
            var errorDescription: String? { "Enable the Gemini provider in settings." }
        }
        let upstream = Upstream()
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: upstream), upstream.localizedDescription)
    }

    func testTheWordsMustBeAdjacentNotJustBothPresent() {
        // Both words appear, but not as the phrase "Antigravity provider" — the
        // substring check must not be fooled by the two words merely co-occurring.
        struct Upstream: LocalizedError {
            var errorDescription: String? { "Antigravity is required; the provider rejected the request." }
        }
        let upstream = Upstream()
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: upstream), upstream.localizedDescription)
    }

    func testEmbeddedInsideALongerWordDoesNotAccidentallyMatch() {
        // "…Antigravity providers…" (plural) does not contain the exact substring
        // "Antigravity provider" followed by a word boundary — but
        // localizedCaseInsensitiveContains is a plain substring test, so "Antigravity
        // provider" IS a substring of "Antigravity providers". Pinning this rather
        // than assuming: the rule is deliberately loose, not word-boundary-aware.
        struct Upstream: LocalizedError {
            var errorDescription: String? { "Enable one of the Antigravity providers first." }
        }
        XCTAssertEqual(GeminiErrorCopy.stateMessage(for: Upstream()), ourAdvice,
                       "a plain substring match: 'Antigravity provider' is contained in 'Antigravity providers'")
    }
}
