import XCTest
@testable import Omelette

/// Independent verification of `MCPSummary.sessionLimit` and its wire path through
/// `MCPServer.handle`, against
/// docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md § Design (#12) and
/// § Packages (P2): "A `Double` that is not finite returns the default; otherwise it
/// is clamped to `1...Double(maxSessionLimit)` and only then converted. Strings go
/// through `Double` the same way (so `"7.0"` and `"1e100"` behave like their numeric
/// forms)."
///
/// Written independently of `MCPSessionsTests.swift` (the executor's own file, which
/// already added `testALimitOfAnySizeIsClampedBeforeItBecomesAnInt` and
/// `testAHugeLimitOnTheWireIsAnsweredNotFatal`) and of the pre-existing
/// `MCPSessionsVerificationTests.swift` (a P3 verification file already on main,
/// unrelated to this package).
final class MCPSessionLimitVerificationTests: XCTestCase {
    // MARK: - Direct calls to MCPSummary.sessionLimit, every value the task named

    func testHugePositiveDoubleClampsToTheMaximum() {
        XCTAssertEqual(MCPSummary.sessionLimit(1e100), 15)
    }

    func testHugeNegativeDoubleClampsToOne() {
        XCTAssertEqual(MCPSummary.sessionLimit(-1e100), 1)
    }

    func testPositiveInfinityIsNotFiniteSoItIsTheDefault() {
        XCTAssertEqual(MCPSummary.sessionLimit(Double.infinity), MCPSummary.defaultSessionLimit)
    }

    func testNegativeInfinityIsNotFiniteSoItIsTheDefault() {
        XCTAssertEqual(MCPSummary.sessionLimit(-Double.infinity), MCPSummary.defaultSessionLimit)
    }

    func testNaNIsNotFiniteSoItIsTheDefault() {
        XCTAssertEqual(MCPSummary.sessionLimit(Double.nan), MCPSummary.defaultSessionLimit)
    }

    func testNegativeFiveClampsToOne() {
        XCTAssertEqual(MCPSummary.sessionLimit(-5), 1)
    }

    func testZeroClampsToOne() {
        XCTAssertEqual(MCPSummary.sessionLimit(0), 1)
    }

    func testSixteenClampsToTheMaximumOfFifteen() {
        XCTAssertEqual(MCPSummary.sessionLimit(16), 15)
    }

    func testSevenAsIntPassesThroughUnchanged() {
        XCTAssertEqual(MCPSummary.sessionLimit(7), 7)
    }

    func testSevenAsDoublePassesThroughUnchanged() {
        XCTAssertEqual(MCPSummary.sessionLimit(7.0), 7)
    }

    func testSevenAsStringPassesThroughUnchanged() {
        XCTAssertEqual(MCPSummary.sessionLimit("7"), 7)
    }

    func testSevenPointZeroAsStringPassesThroughUnchanged() {
        XCTAssertEqual(MCPSummary.sessionLimit("7.0"), 7)
    }

    func test1e100AsStringClampsToTheMaximumLikeItsNumericForm() {
        XCTAssertEqual(MCPSummary.sessionLimit("1e100"), 15)
    }

    func testUnparsableStringIsTheDefault() {
        XCTAssertEqual(MCPSummary.sessionLimit("abc"), MCPSummary.defaultSessionLimit)
    }

    func testNilIsTheDefault() {
        XCTAssertEqual(MCPSummary.sessionLimit(nil), MCPSummary.defaultSessionLimit)
    }

    // MARK: - The clamp order the spec states: finite check, THEN clamp, THEN convert.
    // A value between maxSessionLimit and Int(Double.greatestFiniteMagnitude) that
    // would trap if converted to Int before clamping must not trap.

    func testAValueWellPastIntMaxNeverReachesIntConversionUnclamped() {
        // If the implementation clamped after converting to Int (the pre-fix bug),
        // this would trap the process before the assertion ever ran.
        XCTAssertEqual(MCPSummary.sessionLimit(Double.greatestFiniteMagnitude), 15)
    }

    // MARK: - Wire-level: a JSON-RPC get_sessions call with "limit": 1e100 through
    // MCPServer.handle answers instead of trapping (built independently: no shared
    // helpers with MCPSessionsTests.swift).

    private func wireSnapshot() -> StatusSnapshot {
        let now = Date(timeIntervalSince1970: 1_798_000_000)
        let entry = StatusSnapshot.SessionEntry(
            id: "verify-1", title: "Verification chat", project: "Usage tracker",
            lastAt: now, turns: 1, tokens: 100, cost: 1.0, agents: 0, origin: nil
        )
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
            plan: "Max 5x", windows: [], todayCost: nil, weekCost: nil, todayTokens: nil,
            apiEquivalent: nil, sessions: [entry]
        )
        return StatusSnapshot(version: StatusSnapshot.currentVersion, updatedAt: now, services: [service], agents: .none)
    }

    func testWireLevelGetSessionsWithHugeLimitAnswersInsteadOfTrapping() throws {
        let requestLine = #"""
        {"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"get_sessions","arguments":{"limit":1e100}}}
        """#

        let responseLine = MCPServer.handle(requestLine, snapshot: wireSnapshot(), now: Date(timeIntervalSince1970: 1_798_000_000))

        let response = try XCTUnwrap(responseLine, "the server must answer, not trap and produce nothing")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        XCTAssertNil(object["error"], "a huge limit is not a protocol error")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1, "the one chat available, capped by content not by a trap")
    }

    func testWireLevelGetSessionsWithNegativeInfinityLimitAnswersInsteadOfTrapping() throws {
        // JSON has no literal for -Infinity, so this exercises the string path,
        // which the spec says must behave "like their numeric forms".
        let requestLine = #"""
        {"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"get_sessions","arguments":{"limit":"-inf"}}}
        """#

        let responseLine = MCPServer.handle(requestLine, snapshot: wireSnapshot(), now: Date(timeIntervalSince1970: 1_798_000_000))

        let response = try XCTUnwrap(responseLine)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "-inf is not finite, so it must fall back to the default, not trap")
    }
}
