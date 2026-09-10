import XCTest
@testable import Omelette

/// The per-model split of a chat as a value: the row's key, what an empty effort
/// means, and the one promise `SessionSummary`'s own decoder has to keep — a chat
/// encoded before this field existed decodes to a chat with no model rows, not to an
/// unreadable file.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-by-model-design.md § Design.
final class SessionModelSummaryTests: XCTestCase {
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - The row's identity

    func testTheRowIdIsItsModelAndItsEffort() {
        XCTAssertEqual(
            SessionFixture.model(model: "claude-opus-4-5", effort: "xhigh").id,
            "claude-opus-4-5|xhigh"
        )
        XCTAssertEqual(
            SessionFixture.model(model: "gpt-5.6-terra", effort: nil).id,
            "gpt-5.6-terra|",
            "a log with no effort still leaves a stable, unique key"
        )
        XCTAssertEqual(
            SessionModelSummary.key(model: "claude-opus-4-5", effort: "xhigh"),
            SessionFixture.model(model: "claude-opus-4-5", effort: "xhigh").id,
            "the aggregators bucket on the same string the row calls itself"
        )
    }

    func testTheSameModelAtTwoEffortsIsTwoRows() {
        XCTAssertNotEqual(
            SessionModelSummary.key(model: "claude-opus-4-5", effort: "high"),
            SessionModelSummary.key(model: "claude-opus-4-5", effort: "xhigh")
        )
    }

    func testAnEmptyEffortIsNoEffortAtAll() {
        // Both logs write `effort` as a plain string; a writer that emits "" means the
        // same thing as one that omits the field, and one chat must not grow two rows
        // for one model, the second of them labelled with nothing.
        XCTAssertNil(SessionModelSummary.effort(from: nil))
        XCTAssertNil(SessionModelSummary.effort(from: ""))
        XCTAssertNil(SessionModelSummary.effort(from: "   "))
        XCTAssertEqual(SessionModelSummary.effort(from: "xhigh"), "xhigh")
        XCTAssertEqual(
            SessionModelSummary.key(
                model: "claude-opus-4-5", effort: SessionModelSummary.effort(from: "")
            ),
            "claude-opus-4-5|"
        )
    }

    // MARK: - Decoding a chat that predates the field

    func testAChatEncodedWithoutModelsDecodesWithNone() throws {
        // The 2.5.x shape, field for field. Every `TokenBreakdown` counter is present
        // because Swift's synthesized decoder ignores default values; `cost`, `title`
        // and `origin` are optional and are left out on purpose.
        let json = """
        {"id":"d5dff4f0-3038-4ed6-81d6-ddccee879027","providerID":"claude",\
        "projectSlug":"-Users-tester-Projects-alpha",\
        "firstAt":"2026-09-06T09:00:00Z","lastAt":"2026-09-06T11:20:00Z","turns":3,\
        "tokens":{"input":1000,"output":100,"cacheRead":0,"cacheWrite5m":0,\
        "cacheWrite1h":0,"thinking":0},\
        "mainTokens":{"input":1000,"output":100,"cacheRead":0,"cacheWrite5m":0,\
        "cacheWrite1h":0,"thinking":0},\
        "agents":[],"days":[]}
        """

        let chat = try decoder.decode(SessionSummary.self, from: Data(json.utf8))

        XCTAssertEqual(chat.models, [], "no field, no rows — and no thrown error")
        XCTAssertEqual(chat.turns, 3, "the rest of the chat decodes exactly as before")
        XCTAssertNil(chat.title)
    }

    func testAChatRoundTripsItsModelRows() throws {
        let chat = SessionFixture.session(
            id: "s1",
            tokens: SessionFixture.tokens(input: 1_000, output: 100, cost: SessionFixture.cost(input: 3)),
            models: [
                SessionFixture.model(
                    model: "claude-opus-4-5", effort: "xhigh", turns: 2,
                    tokens: SessionFixture.tokens(input: 900, cost: SessionFixture.cost(input: 2.7))
                ),
                SessionFixture.model(model: "claude-haiku-4-5", effort: nil, turns: 1),
            ]
        )

        let restored = try decoder.decode(SessionSummary.self, from: encoder.encode(chat))

        XCTAssertEqual(restored, chat, "every field, model rows and their dollars included")
        XCTAssertEqual(restored.models.map(\.id), ["claude-opus-4-5|xhigh", "claude-haiku-4-5|"])
    }
}
