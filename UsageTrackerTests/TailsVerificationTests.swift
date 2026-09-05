import XCTest
@testable import Omelette

/// Independent verification of `ModelPricing.family(for:)` (commit 77626aa) against a
/// broader set of real-world OpenAI, Claude and Grok ids than the executor's own
/// `ModelPricingFamilyTests`. Written from scratch against the code's stated rule
/// ("gpt-*/o* ids parse into version + codex; tier/size words and dates collapse")
/// rather than by reading the executor's assertions.
final class TailsVerificationTests: XCTestCase {

    // MARK: - OpenAI: context tag, case, dates

    func testContextTagDoesNotBlockTheCodexLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5-codex[1m]"), "gpt-5-codex")
    }

    func testFamilyIsCaseInsensitive() {
        XCTAssertEqual(ModelPricing.family(for: "GPT-5-Codex"), "gpt-5-codex")
    }

    func testAnEightDigitDateSuffixCollapsesIntoTheCodexLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5-codex-20260101"), "gpt-5-codex")
    }

    /// A dashed (non-8-contiguous-digit) date plus a "-max" tier word after the minor
    /// version: `normalize` never strips it (its regex wants 8 contiguous digits), but
    /// the family regex doesn't need to reach the string's end to match, so the line
    /// still comes out clean.
    func testADashedDateAndATierWordBothCollapse() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5.1-codex-max-2026-01-01"), "gpt-5.1-codex")
    }

    func testMiniAndNanoTiersCollapseIntoTheBareLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5-mini"), "gpt-5")
        XCTAssertEqual(ModelPricing.family(for: "gpt-5-nano"), "gpt-5")
    }

    // MARK: - OpenAI: the "gpt-4o" gap
    //
    // `gptIDRegex` is `^gpt-(\d{1,2})(?:[.-](\d{1,2}))?(?![\d.])(-codex)?`. Its lookahead
    // only excludes another digit or dot after the major/minor run — it does not require
    // a word boundary, so a bare letter glued directly onto the digits ("4o") is simply
    // left unconsumed and ignored. "gpt-4o" and "gpt-4o-mini" therefore both parse as
    // major="4" with nothing after it, landing in the *same* "gpt-4" bucket as plain
    // "gpt-4" — even though GPT-4o is a distinct, widely-used OpenAI model line with
    // its own (much cheaper) price. That defeats the fix's own stated purpose: "every
    // Codex turn lands in one bucket and the per-family split says nothing" — here two
    // different real families still collapse into one.

    func testGPT4oIsClearlyWrong_CollapsesIntoPlainGPT4() {
        // Sensible expectation for a real, well-known OpenAI id: "gpt-4o" is its own
        // line, distinct from "gpt-4". This FAILS against the current implementation,
        // which returns "gpt-4" — see the FINDING in the final report.
        XCTAssertEqual(
            ModelPricing.family(for: "gpt-4o"), "gpt-4o",
            "gpt-4o must not collapse into the plain gpt-4 bucket"
        )
    }

    func testGPT4oMiniIsClearlyWrong_AlsoCollapsesIntoPlainGPT4() {
        XCTAssertEqual(
            ModelPricing.family(for: "gpt-4o-mini"), "gpt-4o",
            "gpt-4o-mini must not collapse into the plain gpt-4 bucket, nor share it with bare gpt-4o"
        )
    }

    /// Was: "documents the actual (buggy) behavior precisely, so a future fix has to
    /// touch this test too — not just the two above." This is that fix, so the test is
    /// inverted: the collision is what must never come back.
    func testGPT4oAndPlainGPT4DoNotCollide() {
        XCTAssertNotEqual(ModelPricing.family(for: "gpt-4o"), ModelPricing.family(for: "gpt-4"))
        XCTAssertNotEqual(ModelPricing.family(for: "gpt-4o-mini"), ModelPricing.family(for: "gpt-4"))
        XCTAssertEqual(ModelPricing.family(for: "gpt-4"), "gpt-4", "plain gpt-4 keeps its own line")
    }

    // MARK: - OpenAI: o-series

    func testOSeriesDropsItsTierWord() {
        XCTAssertEqual(ModelPricing.family(for: "o3-pro-2025-06-10"), "o3")
    }

    func testABareOSeriesID() {
        XCTAssertEqual(ModelPricing.family(for: "o1"), "o1")
    }

    // MARK: - OpenAI: ids outside the stated gpt-*/o* scope

    /// No version right after either recognized prefix ("codex-..." isn't "gpt-..." or
    /// "o<digit>..."), so per the commit's own stated scope this correctly falls to
    /// "other" rather than being guessed at.
    func testCodexMiniLatestHasNoRecognizedPrefixSoItIsOther() {
        XCTAssertEqual(ModelPricing.family(for: "codex-mini-latest"), "other")
    }

    /// Both the gpt and o-series regexes are anchored at the very start of the
    /// (normalized) id, so a provider-prefixed id never reaches them.
    func testAProviderPrefixIsNotStripped() {
        XCTAssertEqual(ModelPricing.family(for: "openai/gpt-5"), "other")
    }

    func testEmptyStringIsOtherNotEmpty() {
        let f = ModelPricing.family(for: "")
        XCTAssertEqual(f, "other")
        XCTAssertFalse(f.isEmpty)
    }

    // MARK: - Claude / Grok untouched

    func testClaudeContextTaggedID() {
        XCTAssertEqual(ModelPricing.family(for: "claude-opus-4-8[1m]"), "opus")
    }

    func testClaudeSonnet() {
        XCTAssertEqual(ModelPricing.family(for: "claude-sonnet-4-6"), "sonnet")
    }

    func testClaudeFable() {
        XCTAssertEqual(ModelPricing.family(for: "claude-fable-5"), "fable")
    }

    func testGrokBuildVariantCollapsesIntoItsLine() {
        XCTAssertEqual(ModelPricing.family(for: "grok-4.6-build"), "grok-4.6")
    }

    /// No version right after the "grok-" prefix, so there is no line to collapse to.
    func testGrokWithNoVersionAfterThePrefixFallsBackToGrok() {
        XCTAssertEqual(ModelPricing.family(for: "grok-build-0.1"), "grok")
    }

    // MARK: - Never empty, across the whole attack list

    func testFamilyNeverReturnsEmptyString() {
        let ids = [
            "gpt-5-codex[1m]", "GPT-5-Codex", "gpt-5-codex-20260101",
            "gpt-5.1-codex-max-2026-01-01", "gpt-5-mini", "gpt-5-nano",
            "gpt-4o", "gpt-4o-mini", "o3-pro-2025-06-10", "o1",
            "codex-mini-latest", "openai/gpt-5", "",
            "claude-opus-4-8[1m]", "claude-sonnet-4-6", "claude-fable-5",
            "grok-4.6-build", "grok-build-0.1",
        ]
        for id in ids {
            XCTAssertFalse(ModelPricing.family(for: id).isEmpty, "family(for: \"\(id)\") was empty")
        }
    }
}
