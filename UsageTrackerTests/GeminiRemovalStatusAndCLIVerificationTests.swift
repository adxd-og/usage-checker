import XCTest
@testable import Omelette

/// Independent verification of the liquid-glass redesign spec, P8 row: "the `gemini`
/// entry in the provider registry / `status.json` / CLI and MCP output ... go in P8"
/// (line 238). Builds a real `StatusSnapshot` through `StatusFileWriter.build`, from
/// real `ServiceSnapshot` fixtures (never a hand-built `StatusSnapshot` literal), for a
/// claude + antigravity poll — the shape a post-P8 launch actually produces — and reads
/// it back through the three renderers the CLI and MCP server hand to a person or a
/// model: `StatusText`, `StatusLineText`, `MCPSummary`.
///
/// Antigravity's own "Gemini models" bucket (`AntigravityProvider.snapshot`, bucket id
/// `antigravity_gemini`) is explicitly in scope and expected to print — the spec keeps
/// "everything Gemini inside Antigravity" — so every assertion here strips that one
/// allowed phrase out before checking for a stray "Gemini" the removed provider would
/// have left behind (a service literally named "Gemini", or its old "Gemini CLI" wording).
final class GeminiRemovalStatusAndCLIVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_500_000)

    private func antigravity() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", icon: "circle.hexagongrid", plan: nil,
            buckets: [
                Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 31, kind: .modelSpecific),
                Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 12, kind: .modelSpecific),
            ],
            at: now
        )
    }

    private func claude() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 40, kind: .session)],
            at: now
        )
    }

    private func withGeminiPhraseRemoved(_ text: String) -> String {
        // The only allowed appearance of the word, case-insensitively, is Antigravity's
        // "Gemini models" bucket label. Strip both cases (StatusText/MCPSummary differ
        // in whether they lowercase window labels) before scanning for anything else.
        text
            .replacingOccurrences(of: "Gemini models", with: "")
            .replacingOccurrences(of: "gemini models", with: "")
    }

    // MARK: - StatusText (`omelette status`)

    func testStatusTextForClaudeAndAntigravityHasNoStrayGeminiBesidesTheBucketLabel() {
        let snapshot = StatusFileWriter.build(
            services: [claude(), antigravity()], costs: [:], agents: .none, now: now
        )
        let rendered = StatusText.render(snapshot: snapshot, now: now)

        XCTAssertTrue(rendered.contains("Gemini models"), "Antigravity's own bucket label must still print")
        let sanitized = withGeminiPhraseRemoved(rendered)
        XCTAssertFalse(
            sanitized.localizedCaseInsensitiveContains("gemini"),
            "no other mention of Gemini in the rendered status text:\n\(rendered)"
        )
        XCTAssertFalse(rendered.contains("Gemini CLI"))
    }

    func testStatusTextForClaudeAloneHasNoGeminiAtAll() {
        let snapshot = StatusFileWriter.build(services: [claude()], costs: [:], agents: .none, now: now)
        let rendered = StatusText.render(snapshot: snapshot, now: now)
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("gemini"), rendered)
    }

    // MARK: - StatusLineText (`omelette statusline`)

    /// `StatusLineText` never prints a window's label at all (only the gauge, the
    /// percent and the reset), so this is really "gemini never appears here, whichever
    /// window (the 31% Gemini pool or the 12% Claude & GPT pool) ends up the headline".
    func testStatusLineTextForAntigravityHasNoGeminiWhicheverWindowLeads() {
        let snapshot = StatusFileWriter.build(
            services: [claude(), antigravity()], costs: [:], agents: .none, now: now
        )
        XCTAssertTrue(snapshot.isFresh(now: now))
        let rendered = StatusLineText.render(snapshot: snapshot, provider: "antigravity", now: now, colour: false)
        XCTAssertFalse(rendered.isEmpty, "the antigravity service must have produced a line")
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("gemini"), rendered)
    }

    // MARK: - MCPSummary (`get_usage`)

    func testMCPUsageSummaryHasNoStrayGeminiBesidesTheLowercasedBucketLabel() {
        let snapshot = StatusFileWriter.build(
            services: [claude(), antigravity()], costs: [:], agents: .none, now: now
        )
        let rendered = MCPSummary.usage(snapshot: snapshot, now: now)

        XCTAssertTrue(rendered.contains("gemini models"), "the window label is lowercased in a sentence:\n\(rendered)")
        let sanitized = withGeminiPhraseRemoved(rendered)
        XCTAssertFalse(
            sanitized.localizedCaseInsensitiveContains("gemini"),
            "no other mention of Gemini in the MCP usage summary:\n\(rendered)"
        )
        XCTAssertFalse(rendered.contains("Gemini CLI"))
    }

    func testMCPUsageSummaryForClaudeAloneHasNoGeminiAtAll() {
        let snapshot = StatusFileWriter.build(services: [claude()], costs: [:], agents: .none, now: now)
        let rendered = MCPSummary.usage(snapshot: snapshot, now: now)
        XCTAssertFalse(rendered.localizedCaseInsensitiveContains("gemini"), rendered)
    }
}
