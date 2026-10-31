import XCTest
@testable import Omelette

/// Tester's verification of `ProviderGridRules.agentsCard` after the fix round (whole-branch
/// review of 4.0, rulings 5 and 6): every provider off or loading still has a card to reach when
/// sessions run, and a sole provider's home page lists every session when its own card would not.
/// The whole input space is crossed against an oracle written from the rulings, not read off the code.
final class ProviderGridRulesAgentsCardVerificationTests: XCTestCase {
    private let pages: [String?] = [nil, "claude", "codex", "grok", "antigravity", "anthropic-admin", "cursor"]
    private let sourceSets: [Set<AgentSource>] = [[], [.claude], [.codex], [.claude, .codex]]

    private func oracle(
        _ page: String?, count: Int, sources: Set<AgentSource>, empty: Bool
    ) -> ProviderGridRules.AgentsCard? {
        if empty { return sources.isEmpty ? nil : .allSessions }
        guard let page else { return .allSessions }
        let own = AgentSource(rawValue: page)
        let someoneElses = !sources.subtracting(own.map { [$0] } ?? []).isEmpty
        if count == 1 && someoneElses { return .allSessions }
        if let own { return .provider(own) }
        return nil
    }

    func testEveryPageCountSourceSetAndBodyAgreesWithTheRulings() {
        var failures: [String] = []
        var runs = 0
        for page in pages {
            for count in 0...5 {
                for sources in sourceSets {
                    for empty in [false, true] {
                        runs += 1
                        let got = ProviderGridRules.agentsCard(
                            serviceID: page, providerCount: count, sessionSources: sources, bodyIsEmpty: empty
                        )
                        let want = oracle(page, count: count, sources: sources, empty: empty)
                        if got != want {
                            failures.append("page \(String(describing: page)), \(count) providers, sources \(sources.map(\.rawValue).sorted()), empty \(empty): \(String(describing: got)), expected \(String(describing: want))")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(runs, 7 * 6 * 4 * 2)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(runs):\n\(failures.prefix(6).joined(separator: "\n"))")
    }

    /// The default keeps the old call sites meaning what they meant: a body with tiles.
    func testTheEmptyBodyDefaultsToOff() {
        XCTAssertEqual(
            ProviderGridRules.agentsCard(serviceID: "grok", providerCount: 3, sessionSources: [.claude]),
            ProviderGridRules.agentsCard(serviceID: "grok", providerCount: 3, sessionSources: [.claude], bodyIsEmpty: false)
        )
        XCTAssertNil(ProviderGridRules.agentsCard(serviceID: "grok", providerCount: 3, sessionSources: [.claude]))
    }

    /// The named cases of the rulings, by hand, so a wrong oracle cannot hide a wrong rule.
    func testTheCasesTheRulingsNameByHand() {
        // 5: every provider off, sessions waiting.
        XCTAssertEqual(ProviderGridRules.agentsCard(serviceID: nil, providerCount: 0, sessionSources: [.codex], bodyIsEmpty: true), .allSessions)
        XCTAssertNil(ProviderGridRules.agentsCard(serviceID: nil, providerCount: 0, sessionSources: [], bodyIsEmpty: true))
        // 6: only Claude is on, two Codex sessions need the user.
        XCTAssertEqual(ProviderGridRules.agentsCard(serviceID: "claude", providerCount: 1, sessionSources: [.codex]), .allSessions)
        // ... and only Codex is on, with Claude sessions.
        XCTAssertEqual(ProviderGridRules.agentsCard(serviceID: "codex", providerCount: 1, sessionSources: [.claude]), .allSessions)
        // Grok alone, any session at all.
        XCTAssertEqual(ProviderGridRules.agentsCard(serviceID: "grok", providerCount: 1, sessionSources: [.codex]), .allSessions)
        XCTAssertNil(ProviderGridRules.agentsCard(serviceID: "grok", providerCount: 1, sessionSources: []))
        // Among several, a page lists its own whatever else runs.
        XCTAssertEqual(ProviderGridRules.agentsCard(serviceID: "claude", providerCount: 2, sessionSources: [.codex]), .provider(.claude))
        XCTAssertNil(ProviderGridRules.agentsCard(serviceID: "antigravity", providerCount: 2, sessionSources: [.claude, .codex]))
    }
}
