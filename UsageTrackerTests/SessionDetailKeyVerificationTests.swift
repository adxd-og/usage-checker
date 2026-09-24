import XCTest
@testable import Omelette

/// Independent verification of `SessionListRule.detailKey`, from the spec rather than
/// from the executor's own `SessionDetailKeyTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "`DetailKey` carries a content fingerprint (`lastAt`, `turns`, `tokens`,
/// `agents.count`, `days.count`, `models.count`)". Claim under test: an open chat's key
/// changes when turns, lastAt, tokens or the agent/day/model counts change, and a
/// collapsed chat's key ignores all of them.
final class SessionDetailKeyVerificationTests: XCTestCase {
    private func baseline(
        id: String = "row-9",
        lastAt: Date = SessionFixture.at(hoursBefore: 2),
        turns: Int = 40,
        tokens: TokenBreakdown = SessionFixture.tokens(input: 5_000, output: 500),
        agents: [SessionAgentSummary] = [SessionFixture.agent(id: "a0"), SessionFixture.agent(id: "a1")],
        days: [SessionDaySummary] = [SessionFixture.day(daysBefore: 0), SessionFixture.day(daysBefore: 1)],
        models: [SessionModelSummary] = [SessionFixture.model(model: "claude-opus-4-5")]
    ) -> SessionSummary {
        SessionFixture.session(
            id: id, lastAt: lastAt, turns: turns, tokens: tokens,
            agents: agents, days: days, models: models
        )
    }

    // MARK: - Open chat: every claimed field moves the key

    func testANewLastAtChangesTheOpenKey() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: true, allAgents: false, allDays: false, allModels: false)
        let laterSession = baseline(lastAt: SessionFixture.at(hoursBefore: 1))
        let b = SessionListRule.detailKey(session: laterSession, expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastAt, SessionFixture.at(hoursBefore: 2))
        XCTAssertEqual(b.lastAt, SessionFixture.at(hoursBefore: 1))
    }

    func testAChangedTurnCountChangesTheOpenKey() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: true, allAgents: false, allDays: false, allModels: false)
        let b = SessionListRule.detailKey(session: baseline(turns: 41), expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
    }

    func testAChangedTokenTotalChangesTheOpenKey() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: true, allAgents: false, allDays: false, allModels: false)
        let grown = baseline(tokens: SessionFixture.tokens(input: 5_000, output: 501))
        let b = SessionListRule.detailKey(session: grown, expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
    }

    func testAnAddedAgentChangesTheOpenKeyByCountAlone() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: true, allAgents: false, allDays: false, allModels: false)
        let moreAgents = baseline(agents: [SessionFixture.agent(id: "a0"), SessionFixture.agent(id: "a1"), SessionFixture.agent(id: "a2")])
        let b = SessionListRule.detailKey(session: moreAgents, expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.agentCount, 2)
        XCTAssertEqual(b.agentCount, 3)
    }

    func testAnAddedDayChangesTheOpenKey() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: true, allAgents: false, allDays: false, allModels: false)
        let moreDays = baseline(days: [SessionFixture.day(daysBefore: 0), SessionFixture.day(daysBefore: 1), SessionFixture.day(daysBefore: 2)])
        let b = SessionListRule.detailKey(session: moreDays, expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
    }

    func testAnAddedModelChangesTheOpenKey() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: true, allAgents: false, allDays: false, allModels: false)
        let moreModels = baseline(models: [SessionFixture.model(model: "claude-opus-4-5"), SessionFixture.model(model: "claude-sonnet-5")])
        let b = SessionListRule.detailKey(session: moreModels, expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
    }

    /// The fingerprint is a count, not an identity: reordering or renaming the agents
    /// without changing how many there are must not perturb the key on its own account
    /// (agentCount is unchanged; only lastAt/turns/tokens would move it, tested above).
    func testReorderingAgentsWithTheSameCountDoesNotChangeTheKeyByItself() {
        let original = baseline(agents: [SessionFixture.agent(id: "a0"), SessionFixture.agent(id: "a1")])
        let reordered = baseline(agents: [SessionFixture.agent(id: "a1"), SessionFixture.agent(id: "a0")])
        let a = SessionListRule.detailKey(session: original, expanded: true, allAgents: false, allDays: false, allModels: false)
        let b = SessionListRule.detailKey(session: reordered, expanded: true, allAgents: false, allDays: false, allModels: false)
        XCTAssertEqual(a, b)
    }

    // MARK: - Collapsed chat: the same fields are ignored

    func testACollapsedKeyIgnoresANewLastAt() {
        let a = SessionListRule.detailKey(session: baseline(), expanded: false, allAgents: false, allDays: false, allModels: false)
        let later = baseline(lastAt: SessionFixture.at(hoursBefore: 0.1))
        let b = SessionListRule.detailKey(session: later, expanded: false, allAgents: false, allDays: false, allModels: false)
        XCTAssertEqual(a, b)
    }

    func testACollapsedKeyIgnoresTurnsTokensAndCounts() {
        let grown = baseline(
            turns: 999,
            tokens: SessionFixture.tokens(input: 999_999, output: 999_999),
            agents: (0..<50).map { SessionFixture.agent(id: "a\($0)") },
            days: (0..<50).map { SessionFixture.day(daysBefore: $0) },
            models: (0..<10).map { SessionFixture.model(model: "m\($0)") }
        )
        let a = SessionListRule.detailKey(session: baseline(), expanded: false, allAgents: false, allDays: false, allModels: false)
        let b = SessionListRule.detailKey(session: grown, expanded: false, allAgents: false, allDays: false, allModels: false)
        XCTAssertEqual(a, b, "a collapsed row must not restart its task on every poll")
    }

    /// The collapsed key does not merely happen to equal by coincidence — it zeroes
    /// the fingerprint fields entirely, per the rule's own contract.
    func testACollapsedKeyZeroesTheFingerprint() {
        let key = SessionListRule.detailKey(session: baseline(), expanded: false, allAgents: false, allDays: false, allModels: false)
        XCTAssertEqual(key.lastAt, .distantPast)
        XCTAssertEqual(key.turns, 0)
        XCTAssertEqual(key.tokens, .zero)
        XCTAssertEqual(key.agentCount, 0)
        XCTAssertEqual(key.dayCount, 0)
        XCTAssertEqual(key.modelCount, 0)
    }

    /// Two different chats, both collapsed, still must not collide — the row id is not
    /// part of what gets ignored.
    func testTwoDifferentChatsCollapsedNeverShareAKey() {
        let a = SessionListRule.detailKey(session: baseline(id: "chat-a"), expanded: false, allAgents: false, allDays: false, allModels: false)
        let b = SessionListRule.detailKey(session: baseline(id: "chat-b"), expanded: false, allAgents: false, allDays: false, allModels: false)
        XCTAssertNotEqual(a, b)
    }
}
