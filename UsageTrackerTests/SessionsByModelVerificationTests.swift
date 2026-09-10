import XCTest
@testable import Omelette

/// Independent verification of the M1 "Sessions by model" package, at the value-type
/// and rule level: `SessionSummary.models` decoding, `SessionModelSummary.effort`
/// folding, `SessionListRule.pickModels` / `showsModels`, `SessionCopy.modelColumns`
/// and `SessionDetail.build(allModels:)`.
///
/// Written from the spec, not from the executor's own tests:
/// docs/superpowers/specs/2026-09-10-sessions-by-model-design.md § Design, § UI.
final class SessionsByModelVerificationTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - SessionSummary decodes without `models`

    func testASessionSummaryJSONWithNoModelsKeyDecodesToAnEmptyArray() throws {
        // A different chat shape from the executor's own decode test (agents non-empty,
        // a title, an origin) so the independent check isn't just a copy with renamed
        // fields: every other property must still decode correctly with `models` absent.
        let json = """
        {"id":"9c1e2222-aaaa-bbbb-cccc-000000000001","providerID":"codex",\
        "title":"Refactor the parser","projectSlug":"%2Ftmp%2Fverify",\
        "origin":"codex_exec",\
        "firstAt":"2026-09-04T08:00:00Z","lastAt":"2026-09-04T09:30:00Z","turns":7,\
        "tokens":{"input":5000,"output":400,"cacheRead":100,"cacheWrite5m":0,\
        "cacheWrite1h":0,"thinking":0},\
        "mainTokens":{"input":4000,"output":300,"cacheRead":100,"cacheWrite5m":0,\
        "cacheWrite1h":0,"thinking":0},\
        "agents":[],"days":[]}
        """

        let chat = try decoder.decode(SessionSummary.self, from: Data(json.utf8))

        XCTAssertEqual(chat.models, [], "no key at all, not an empty array written explicitly")
        XCTAssertEqual(chat.turns, 7, "every other field decodes exactly as it did before models existed")
        XCTAssertEqual(chat.title, "Refactor the parser")
        XCTAssertEqual(chat.origin, "codex_exec")
    }

    // MARK: - Effort folding

    func testWhitespaceOnlyEffortVariantsAllFoldToNilAndShareOneKey() {
        // Tab, newline and a mix of both: whatever whitespace a log could plausibly
        // contain in the field, not just the plain-space case the executor already wrote.
        for raw in ["\t", "\n", "  \t \n ", "\r\n"] {
            XCTAssertNil(SessionModelSummary.effort(from: raw), "raw effort \(raw.debugDescription)")
        }
        XCTAssertEqual(
            SessionModelSummary.key(model: "gpt-6-astra", effort: SessionModelSummary.effort(from: "\n")),
            SessionModelSummary.key(model: "gpt-6-astra", effort: nil),
            "a log that writes whitespace where an effort belongs must land in the same row as one with none"
        )
    }

    // MARK: - SessionListRule.pickModels / modelsByCost

    func testPickModelsAtExactlyTheCapKeepsAllSixInCostOrder() {
        let rows = (1...6).map {
            SessionFixture.model(
                model: "model-\($0)", effort: "high", turns: 1,
                tokens: SessionFixture.tokens(input: 1_000, cost: SessionFixture.cost(input: Double($0)))
            )
        }.shuffled()

        let picked = SessionListRule.pickModels(rows)

        XCTAssertEqual(picked.count, 6, "six rows at the cap draws every one of them")
        XCTAssertEqual(
            picked.map { $0.tokens.cost?.total ?? -1 }, [6, 5, 4, 3, 2, 1],
            "most expensive first regardless of the array's own order"
        )
    }

    func testPickModelsAtOneOverTheCapDropsOnlyTheCheapestRow() {
        let rows = (1...7).map {
            SessionFixture.model(
                model: "model-\($0)", effort: "high", turns: 1,
                tokens: SessionFixture.tokens(input: 1_000, cost: SessionFixture.cost(input: Double($0)))
            )
        }

        let picked = SessionListRule.pickModels(rows)

        XCTAssertEqual(picked.count, 6)
        XCTAssertFalse(picked.contains { $0.model == "model-1" }, "model-1 is the single cheapest row")
        XCTAssertEqual(picked.map(\.model).first, "model-7", "the most expensive row leads")
    }

    // MARK: - SessionListRule.showsModels

    func testShowsModelsIsFalseForExactlyOneRowWithNoEffort() {
        XCTAssertFalse(
            SessionListRule.showsModels([SessionFixture.model(model: "claude-sonnet-4-5", effort: nil)]),
            "one model, no effort: the split line above already states this chat's whole spend"
        )
    }

    func testShowsModelsIsTrueForExactlyOneRowThatCarriesAnEffort() {
        XCTAssertTrue(
            SessionListRule.showsModels([SessionFixture.model(model: "claude-sonnet-4-5", effort: "xhigh")]),
            "the effort is a fact stated nowhere else on the expanded chat"
        )
    }

    func testShowsModelsIsTrueForTwoRowsEvenWithNoEffortOnEither() {
        XCTAssertTrue(
            SessionListRule.showsModels([
                SessionFixture.model(model: "claude-sonnet-4-5", effort: nil),
                SessionFixture.model(model: "claude-haiku-4-5", effort: nil),
            ]),
            "two models is a split worth drawing on its own"
        )
    }

    func testShowsModelsIsFalseForZeroRows() {
        XCTAssertFalse(SessionListRule.showsModels([]))
    }

    // MARK: - SessionCopy.modelColumns

    func testModelColumnsFallsBackToTheRawIdWhenModelPricingHasNoDisplayName() {
        // "unknown" is `ModelPricing.isSynthetic`'s own second case (distinct from the
        // executor's "<synthetic>" fixture) — both must fall back to the raw id.
        let columns = SessionCopy.modelColumns(
            SessionFixture.model(model: "unknown", effort: nil, turns: 5)
        )

        XCTAssertEqual(columns.model, "unknown")
        XCTAssertEqual(columns.turns, "5")
    }

    func testModelColumnsRendersADashForARowWithNoCost() {
        let columns = SessionCopy.modelColumns(
            SessionFixture.model(
                model: "claude-sonnet-4-5", effort: "medium", turns: 7,
                tokens: SessionFixture.tokens(input: 500, output: 20) // no `cost:` given → nil
            )
        )

        XCTAssertEqual(
            columns,
            SessionModelColumns(
                id: "claude-sonnet-4-5|medium", model: "Sonnet 4.5", effort: "medium",
                turns: "7", tokens: "520", cost: "—"
            )
        )
    }

    // MARK: - SessionDetail.build(allModels:)

    private func manyModelChat(count: Int) -> SessionSummary {
        SessionFixture.session(
            id: "verify-many-models", turns: 90,
            tokens: SessionFixture.tokens(input: 9_000_000, cost: SessionFixture.cost(input: 90)),
            models: (1...count).map {
                SessionFixture.model(
                    model: "verify-model-\($0)", effort: "high", turns: 3,
                    tokens: SessionFixture.tokens(
                        input: 1_000, cost: SessionFixture.cost(input: Double($0))
                    )
                )
            }
        )
    }

    func testSessionDetailBuildDefaultsToTheCappedSixModelRows() {
        let detail = SessionDetail.build(
            session: manyModelChat(count: 9),
            allAgents: false, allDays: false,
            // `allModels` omitted: this is the default the ten pre-existing call sites
            // (four of them in the verifier's own file) rely on.
            calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.modelRows.count, 6, "a freshly opened chat starts at the cap")
        XCTAssertEqual(detail.hiddenModels, 3)
        XCTAssertEqual(detail.totalModels, 9, "the real count regardless of the cap")
        // "verify-model-9" is not synthetic, so `ModelPricing.displayName` prettifies it
        // rather than falling back to the raw id — that fallback is exercised above by
        // an id `isSynthetic` recognizes ("unknown").
        XCTAssertEqual(detail.modelRows.first?.model, "Verify Model 9", "most expensive first")
    }

    func testSessionDetailBuildWithAllModelsTrueDrawsEveryRow() {
        let detail = SessionDetail.build(
            session: manyModelChat(count: 9),
            allAgents: false, allDays: false, allModels: true,
            calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.modelRows.count, 9)
        XCTAssertEqual(detail.hiddenModels, 0)
        XCTAssertEqual(detail.totalModels, 9)
    }
}
