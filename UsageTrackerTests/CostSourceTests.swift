import XCTest
@testable import Omelette

/// The dashboard's per-provider answer to "where do these dollars come from?", and the
/// model-name rendering that answer relies on. Both are pure functions, so they're
/// asserted directly rather than through a view.
final class CostSourceTests: XCTestCase {

    // MARK: - Which providers can be costed

    func testEveryCLIWithATurnLogHasALocalCostSource() {
        let claude = DashboardState.costSource(for: "claude")
        XCTAssertTrue(claude.hasBreakdown)
        XCTAssertEqual(claude.shortName, "Claude Code CLI")
        XCTAssertEqual(claude.longName, "Claude Code's session logs")
        XCTAssertNil(claude.reason)

        let grok = DashboardState.costSource(for: "grok")
        XCTAssertTrue(grok.hasBreakdown)
        XCTAssertEqual(grok.shortName, "Grok CLI")
        XCTAssertEqual(grok.longName, "the Grok CLI's session logs")
        XCTAssertNil(grok.reason)
    }

    func testAntigravitySaysItKeepsNoTokenLog() {
        // Verbatim, because it is the whole content of the empty state: Antigravity's
        // local state has no token counts in the clear, and no amount of parsing will
        // change that — the user should stop looking.
        XCTAssertEqual(
            DashboardState.costSource(for: "antigravity"),
            .unavailable(reason: "Antigravity doesn't keep a local token log, so costs can't be computed. Quota over time is charted instead.")
        )
    }

    func testCodexHasALocalCostLog() {
        let codex = DashboardState.costSource(for: "codex")
        XCTAssertTrue(codex.hasBreakdown)
        XCTAssertEqual(codex.shortName, "Codex CLI")
        XCTAssertEqual(codex.longName, "the Codex CLI's session logs")
        XCTAssertNil(codex.reason, "the old 'running totals' empty state is retired")
    }

    func testGeminiSaysItIsNotSupportedYet() {
        XCTAssertEqual(
            DashboardState.costSource(for: "gemini"),
            .unavailable(reason: "Cost accounting for the Gemini CLI isn't supported yet. Quota over time is charted instead.")
        )
    }

    func testAnUnknownProviderGetsAGenericButTruthfulReason() {
        let other = DashboardState.costSource(for: "anthropic-admin")
        XCTAssertEqual(
            other,
            .unavailable(reason: "This provider keeps no local cost log, so costs can't be computed. Quota over time is charted instead.")
        )
        XCTAssertNil(other.shortName)
        XCTAssertNil(other.longName)
    }

    func testTheAggregatorExistsExactlyWhenTheCostSourceSaysItDoes() {
        for id in ["claude", "grok", "codex", "gemini", "antigravity", "anthropic-admin"] {
            XCTAssertEqual(
                DashboardState.costAggregator(for: id) != nil,
                DashboardState.costSource(for: id).hasBreakdown,
                "\(id): a provider promising a breakdown must have something to build it from"
            )
        }
    }

    // MARK: - Model display names

    func testGrokBuildVariantsRenderAsTheirModelLine() {
        XCTAssertEqual(ModelPricing.displayName(for: "grok-4.6-build"), "Grok 4.6")
        XCTAssertEqual(ModelPricing.displayName(for: "grok-4.6"), "Grok 4.6")
        XCTAssertEqual(ModelPricing.displayName(for: "grok-4.20-multi-agent-0309"), "Grok 4.20")
        // Both variants of one line share a family bucket in the daily cost split.
        XCTAssertEqual(ModelPricing.family(for: "grok-4.6-build"), "grok-4.6")
        XCTAssertEqual(ModelPricing.family(for: "grok-4.6"), "grok-4.6")
    }

    func testAGrokIDWithoutAVersionStillReadsAsAName() {
        XCTAssertEqual(ModelPricing.displayName(for: "grok-build-0.1"), "Grok Build 0.1")
        XCTAssertEqual(ModelPricing.family(for: "grok-build-0.1"), "grok")
    }

    func testAnUnknownButPricedIDGetsAPrettifiedName() {
        // models.dev knows this one; the UI hides any model whose display name is nil,
        // so a priced model must never come back nil.
        XCTAssertEqual(ModelPricing.displayName(for: "gemini-3.1-pro-preview"), "Gemini 3.1 Pro Preview")
        XCTAssertEqual(ModelPricing.displayName(for: "gpt-5.6-luna"), "GPT 5.6 Luna")
        // Dashes become spaces, words are capitalized, and the release-date suffix is
        // dropped — the exact string, so a change to prettifyID has to be deliberate.
        XCTAssertEqual(
            ModelPricing.displayName(for: "some-brand-new-model-20260101"),
            "Some Brand New Model"
        )
    }

    func testSyntheticIDsStayHidden() {
        XCTAssertNil(ModelPricing.displayName(for: "<synthetic>"))
        XCTAssertNil(ModelPricing.displayName(for: "unknown"))
    }

    func testClaudeNamesAreUnchanged() {
        XCTAssertEqual(ModelPricing.displayName(for: "claude-opus-4-5"), "Opus 4.5")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ModelPricing.family(for: "claude-opus-4-5"), "opus")
    }
}
