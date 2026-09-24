import XCTest
@testable import Omelette

/// Independent verification of `get_sessions`' API-equivalent labelling
/// (`MCPSummary.sessionsQualifier`, `MCPServer.sessionsData`), derived from
/// `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)": "`sessionsData` carries `apiEquivalent`; `MCPSummary.sessions`
/// ends with one qualifier line". Not from `MCPSessionsTests`. Focus: the qualifier's
/// four-way truth table (flag × has-a-cost), that a `false`-flagged provider's dollars
/// never trip a `true`-flagged provider's absent qualifier or vice versa across mixed
/// providers, and `sessionsData`'s raw pass-through of true / false / absent.
final class MCPSessionsVerification2Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func entry(id: String, cost: Double?) -> StatusSnapshot.SessionEntry {
        StatusSnapshot.SessionEntry(
            id: id, title: "Chat \(id)", project: "Project", lastAt: now.addingTimeInterval(-3600),
            turns: 10, tokens: 1000, cost: cost, agents: 0, origin: nil
        )
    }

    private func service(
        id: String, apiEquivalent: Bool?, sessions: [StatusSnapshot.SessionEntry]
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: id.capitalized, state: "ok", retained: false, retainedAt: nil, plan: nil,
            windows: [], todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: apiEquivalent,
            sessions: sessions
        )
    }

    // MARK: - sessionsQualifier: the four-way truth table

    private func rows(
        _ pairs: [(apiEquivalent: Bool?, cost: Double?)]
    ) -> [(service: StatusSnapshot.Service, session: StatusSnapshot.SessionEntry)] {
        pairs.enumerated().map { index, pair in
            let session = entry(id: "s\(index)", cost: pair.cost)
            let svc = service(id: "p\(index)", apiEquivalent: pair.apiEquivalent, sessions: [session])
            return (service: svc, session: session)
        }
    }

    func testFlaggedProviderWithACostQualifies() {
        XCTAssertEqual(MCPSummary.sessionsQualifier(rows([(true, 58.10)])), MCPSummary.sessionsCostQualifier)
    }

    func testFlaggedProviderWithNoCostOnTheListedRowDoesNotQualify() {
        XCTAssertNil(MCPSummary.sessionsQualifier(rows([(true, nil)])))
    }

    func testUnflaggedProviderWithACostDoesNotQualify() {
        XCTAssertNil(MCPSummary.sessionsQualifier(rows([(false, 58.10)])))
    }

    func testAbsentFlagWithACostDoesNotQualify() {
        XCTAssertNil(MCPSummary.sessionsQualifier(rows([(nil, 58.10)])))
    }

    /// A pay-as-you-go chat with dollars sits beside a subscription chat with
    /// dollars: one qualifying row is enough for the whole list, and the PAYG row
    /// does not suppress it.
    func testOneQualifyingRowAmongSeveralIsEnough() {
        XCTAssertEqual(
            MCPSummary.sessionsQualifier(rows([(false, 12.0), (true, 4.0), (nil, 1.0)])),
            MCPSummary.sessionsCostQualifier
        )
    }

    func testEmptyListHasNoQualifier() {
        XCTAssertNil(MCPSummary.sessionsQualifier([]))
    }

    // MARK: - sessionsData: apiEquivalent copied as-is

    func testSessionsDataCopiesTrue() throws {
        let data = MCPServer.sessionsData(
            snapshot(services: [service(id: "claude", apiEquivalent: true, sessions: [entry(id: "s1", cost: 4.2)])]),
            provider: nil, limit: 10
        )
        let services = try XCTUnwrap(data["services"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(services.first?["apiEquivalent"] as? Bool), true)
    }

    func testSessionsDataCopiesFalse() throws {
        let data = MCPServer.sessionsData(
            snapshot(services: [service(id: "codex", apiEquivalent: false, sessions: [entry(id: "s1", cost: 4.2)])]),
            provider: nil, limit: 10
        )
        let services = try XCTUnwrap(data["services"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(services.first?["apiEquivalent"] as? Bool), false)
    }

    /// A provider whose file carries no flag at all gets no key — not `null`, not a
    /// guessed `false`.
    func testSessionsDataOmitsTheKeyWhenTheFileHasNoFlag() throws {
        let data = MCPServer.sessionsData(
            snapshot(services: [service(id: "grok", apiEquivalent: nil, sessions: [entry(id: "s1", cost: 4.2)])]),
            provider: nil, limit: 10
        )
        let services = try XCTUnwrap(data["services"] as? [[String: Any]])
        XCTAssertNil(services.first?["apiEquivalent"])
        XCTAssertNotNil(services.first?["id"], "the provider itself is still listed")
    }

    private func snapshot(services: [StatusSnapshot.Service]) -> StatusSnapshot {
        StatusSnapshot(version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none)
    }
}
