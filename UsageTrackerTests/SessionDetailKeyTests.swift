import XCTest
@testable import Omelette

/// An open chat rebuilds its by-model, sub-agent and by-day tables when the chat itself
/// changes, not only when it is opened or a cap is lifted: `refreshSessions` replaces
/// the row's summary on every ingest, and a key made of the id and the switches kept
/// the old tables under the new totals. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "`DetailKey` carries a content fingerprint"; report D § 3.
final class SessionDetailKeyTests: XCTestCase {
    private func chat(
        id: String = "chat",
        lastAt: Date = SessionFixture.at(hoursBefore: 1),
        turns: Int = 12,
        tokens: TokenBreakdown = SessionFixture.tokens(input: 1_000, output: 100),
        agents: Int = 1,
        days: Int = 2,
        models: Int = 1
    ) -> SessionSummary {
        SessionFixture.session(
            id: id,
            lastAt: lastAt,
            turns: turns,
            tokens: tokens,
            agents: (0..<agents).map { SessionFixture.agent(id: "a\($0)") },
            days: (0..<days).map { SessionFixture.day(daysBefore: $0) },
            models: (0..<models).map { SessionFixture.model(effort: "e\($0)") }
        )
    }

    private func key(
        _ session: SessionSummary, expanded: Bool = true,
        allAgents: Bool = false, allDays: Bool = false, allModels: Bool = false
    ) -> SessionListRule.DetailKey {
        SessionListRule.detailKey(
            session: session, expanded: expanded,
            allAgents: allAgents, allDays: allDays, allModels: allModels
        )
    }

    func testTheSameChatGivesTheSameKey() {
        XCTAssertEqual(key(chat()), key(chat()))
    }

    func testANewTurnRebuildsTheOpenChat() {
        XCTAssertNotEqual(key(chat(turns: 13)), key(chat()))
    }

    func testALaterReplyRebuildsTheOpenChat() {
        XCTAssertNotEqual(key(chat(lastAt: SessionFixture.at(hoursBefore: 0.5))), key(chat()))
    }

    func testMoreTokensRebuildTheOpenChat() {
        let more = SessionFixture.tokens(input: 1_000, output: 900)
        XCTAssertNotEqual(key(chat(tokens: more)), key(chat()))
    }

    func testANewSubAgentDayOrModelRebuildsTheOpenChat() {
        XCTAssertNotEqual(key(chat(agents: 2)), key(chat()), "a sub-agent row appears")
        XCTAssertNotEqual(key(chat(days: 3)), key(chat()), "a day row appears")
        XCTAssertNotEqual(key(chat(models: 2)), key(chat()), "a model row appears")
    }

    func testOpeningAChatAndLiftingACapStillRebuild() {
        XCTAssertNotEqual(key(chat(), expanded: false), key(chat(), expanded: true))
        XCTAssertNotEqual(key(chat(), allAgents: true), key(chat()))
        XCTAssertNotEqual(key(chat(), allDays: true), key(chat()))
        XCTAssertNotEqual(key(chat(), allModels: true), key(chat()))
    }

    func testTwoChatsNeverShareAKey() {
        XCTAssertNotEqual(key(chat(id: "other")), key(chat()))
    }

    func testAClosedChatDoesNotRestartOnEveryPoll() {
        // A collapsed row draws no tables. Its key ignores the chat's content, so a
        // poll does not restart one no-op task per row in a "Show all" list.
        XCTAssertEqual(key(chat(turns: 13), expanded: false), key(chat(), expanded: false))
    }

    func testTheKeyCarriesTheFingerprintItClaims() {
        let session = chat()
        let k = key(session)
        XCTAssertEqual(k.id, "chat")
        XCTAssertEqual(k.lastAt, session.lastAt)
        XCTAssertEqual(k.turns, 12)
        XCTAssertEqual(k.tokens, session.tokens)
        XCTAssertEqual(k.agentCount, 1)
        XCTAssertEqual(k.dayCount, 2)
        XCTAssertEqual(k.modelCount, 1)
    }
}
