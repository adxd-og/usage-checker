import XCTest
@testable import Omelette

/// `family(for:)` names the model *line* a turn belongs to — the bucket the per-day
/// cost split is drawn from. For OpenAI that means the version, plus the `codex`
/// specialization where the id carries one; the size and tier words a line ships
/// under ("-max", "-mini", "-latest") and the date stamps are noise at that altitude.
final class ModelPricingFamilyTests: XCTestCase {
    func testCodexIdsKeepTheirOwnLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5-codex"), "gpt-5-codex")
    }

    func testATierSuffixDoesNotSplitTheCodexLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5.1-codex-max"), "gpt-5.1-codex")
    }

    func testABareGPTIDIsItsOwnLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5"), "gpt-5")
    }

    func testADateStampedGPTIDCollapsesIntoItsLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-5-2026-01-01"), "gpt-5")
    }

    func testASizeSuffixCollapsesIntoTheLine() {
        XCTAssertEqual(ModelPricing.family(for: "gpt-4.1-mini"), "gpt-4.1")
    }

    func testTheOSeriesLinesAreNamedByTheirNumber() {
        XCTAssertEqual(ModelPricing.family(for: "o3"), "o3")
        XCTAssertEqual(ModelPricing.family(for: "o3-pro"), "o3")
        XCTAssertEqual(ModelPricing.family(for: "o4-mini"), "o4")
    }

    /// An id from a provider we don't parse still has to land somewhere.
    func testAnUnknownIDIsStillOther() {
        XCTAssertEqual(ModelPricing.family(for: "gemini-3.7-flash"), "other")
    }

    /// The OpenAI branch must not disturb the two providers that already had lines.
    func testClaudeAndGrokAreUnchanged() {
        XCTAssertEqual(ModelPricing.family(for: "claude-opus-4-5-20251001"), "opus")
        XCTAssertEqual(ModelPricing.family(for: "grok-4.6-build"), "grok-4.6")
    }
}
