import XCTest
@testable import Omelette

/// Liquid-glass spec § Decisions, "Overview by-model rows" (the owner's visual check of
/// P3): the CLI card keeps 2.7.1's per-model spend for today, one row per model, dearest
/// first, "model · tokens · dollars", at most five rows, none for a model that cost
/// nothing and no block at all on a day with no spend.
final class OverviewByModelTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func entry(_ model: String, cost: Double, tokens: Int = 1_000) -> OverviewCLIRules.ModelEntry {
        (model: model, cost: cost, tokens: tokens, breakdown: TokenBreakdown(input: tokens))
    }

    func testTodaysModelsAreListedDearestFirst() {
        let rows = OverviewCLIRules.modelRows([
            entry("Sonnet 4.5", cost: 3.10, tokens: 40_000),
            entry("Opus 4.5", cost: 41.20, tokens: 1_200_000),
            entry("Haiku 4.5", cost: 0.42, tokens: 9_000),
        ])
        XCTAssertEqual(rows, [
            OverviewCLIRules.ModelRow(model: "Opus 4.5", tokens: 1_200_000, cost: 41.20),
            OverviewCLIRules.ModelRow(model: "Sonnet 4.5", tokens: 40_000, cost: 3.10),
            OverviewCLIRules.ModelRow(model: "Haiku 4.5", tokens: 9_000, cost: 0.42),
        ])
    }

    func testModelsThatCostTheSameAreListedAlphabetically() {
        // The aggregators hand today's models over from a dictionary: equal costs arrive
        // in any order, and the rows must not swap places between two polls.
        let rows = OverviewCLIRules.modelRows([
            entry("gpt-5.6", cost: 2), entry("claude-opus", cost: 2), entry("grok-4", cost: 5),
        ])
        XCTAssertEqual(rows.map(\.model), ["grok-4", "claude-opus", "gpt-5.6"])
    }

    func testAModelThatCostNothingIsLeftOut() {
        let rows = OverviewCLIRules.modelRows([
            entry("Opus 4.5", cost: 1.5), entry("synthetic", cost: 0, tokens: 50_000),
        ])
        XCTAssertEqual(rows.map(\.model), ["Opus 4.5"])
    }

    func testAtMostFiveModelsAreListed() {
        let seven = (1...7).map { entry("model-\($0)", cost: Double($0)) }
        XCTAssertEqual(OverviewCLIRules.modelRowLimit, 5)
        XCTAssertEqual(OverviewCLIRules.modelRows(seven).map(\.model),
                       ["model-7", "model-6", "model-5", "model-4", "model-3"])
        XCTAssertEqual(OverviewCLIRules.modelRows(seven, limit: 2).map(\.model), ["model-7", "model-6"])
        XCTAssertTrue(OverviewCLIRules.modelRows(seven, limit: 0).isEmpty)
        XCTAssertTrue(OverviewCLIRules.modelRows(seven, limit: -1).isEmpty)
    }

    func testADayWithNoSpendHasNoRows() {
        XCTAssertTrue(OverviewCLIRules.modelRows([]).isEmpty)
        XCTAssertTrue(OverviewCLIRules.modelRows([entry("Opus 4.5", cost: 0, tokens: 900)]).isEmpty)
    }

    func testTheBlockIsTitledByModel() {
        XCTAssertEqual(OverviewCopy.byModelTitle, "By model")
    }

    func testARowIsTheModelItsTokensAndItsDollars() {
        XCTAssertEqual(
            OverviewCopy.modelLine(OverviewCLIRules.ModelRow(model: "Opus 4.5", tokens: 1_200_000, cost: 41.2), locale: us),
            "Opus 4.5 · 1.2M tokens · $41.20"
        )
        XCTAssertEqual(
            OverviewCopy.modelLine(OverviewCLIRules.ModelRow(model: "gpt-5.6", tokens: 950, cost: 1_234.5), locale: us),
            "gpt-5.6 · 950 tokens · $1,234.50"
        )
    }
}
