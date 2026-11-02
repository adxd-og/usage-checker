import XCTest
@testable import Omelette

/// `get_usage` says when a window came from Claude Code's status line, and its time (spec
/// 2026-11-02 Claude limits from the status line, § Source tag; session ruling 3): in the
/// paragraph, right after the window's percent, and in the structured data as `source`
/// and `asOf`; a retained provider's advice dates a fed window by the reading. Exact
/// strings, as `MCPSummaryTests`.
final class MCPUsageSourceTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func snapshot(retained: Bool = false) -> StatusSnapshot {
        StatusSnapshot(
            version: 2,
            updatedAt: now,
            services: [StatusSnapshot.Service(
                id: "claude", name: "Claude", state: retained ? "notSignedIn" : "ok", retained: retained,
                // An hour back, as `MCPSummaryRetainedTests` dates it: a two-digit hour
                // reads the same whether the locale pads single digits or not.
                retainedAt: retained ? now.addingTimeInterval(-3600) : nil,
                plan: "Max 5x",
                windows: [
                    StatusSnapshot.Window(
                        id: "five_hour", label: "Session", percent: 42,
                        resetsAt: now.addingTimeInterval(100 * 60), kind: "session",
                        source: "statusLine", asOf: now.addingTimeInterval(-60)
                    ),
                    StatusSnapshot.Window(
                        id: "seven_day", label: "Weekly", percent: 18,
                        resetsAt: now.addingTimeInterval(4 * 86_400 + 175 * 60), kind: "weekly"
                    ),
                ],
                todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: nil
            )],
            agents: .none
        )
    }

    private func usage(_ snapshot: StatusSnapshot) -> String {
        MCPSummary.usage(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
    }

    func testAWindowTheStatusLineFedSaysItCameFromClaudeCodeAndWhen() {
        let text = usage(snapshot())

        XCTAssertTrue(
            text.hasPrefix("Claude (Max 5x): session 42% from Claude Code at 11:19, resets in 1h 40m (13:00); weekly 18%, resets in 4d 2h (Thu 14:15). "),
            text
        )
    }

    /// A signed-out Claude fed by the status line: the provider's own clause keeps its
    /// last-known time, the fed window and the advice carry the reading's.
    func testARetainedProviderIsDatedByTheReadingWhereClaudeCodeFedIt() {
        let text = usage(snapshot(retained: true))

        XCTAssertTrue(text.contains("session 42% from Claude Code at 11:19, resets in 1h 40m (13:00)"), text)
        XCTAssertTrue(text.contains("last known at 10:20; the provider is not reporting now"), text)
        XCTAssertTrue(text.contains("Claude's session window was 42% used when last seen at 11:19"), text)
    }

    /// Re-encoded through the file's own Codable, so the keys reach a client that reads
    /// only the data.
    func testTheStructuredAnswerCarriesTheSourceAndTime() throws {
        let data = MCPServer.usageData(snapshot())

        let service = try XCTUnwrap((data["services"] as? [[String: Any]])?.first)
        let windows = try XCTUnwrap(service["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["source"] as? String, "statusLine")
        XCTAssertEqual(windows.first?["asOf"] as? String, "2026-09-06T11:19:00Z")
        XCTAssertNil(windows.last?["source"])
        XCTAssertNil(windows.last?["asOf"])
    }

    /// The provider's own fetch says nothing — every window already reads as that — and
    /// neither does a source this build does not know. A fed window without its time says
    /// only where it came from.
    func testOnlyTheStatusLineHasWords() {
        XCTAssertEqual(ReadingSource.statusLine.words, "from Claude Code")
        XCTAssertNil(ReadingSource.oauth.words)
        func words(_ source: String?, asOf: Date? = nil) -> String? {
            MCPSummary.sourceWords(
                StatusSnapshot.Window(id: "five_hour", label: "Session", percent: 1, source: source, asOf: asOf),
                now: now, calendar: calendar, locale: locale
            )
        }
        XCTAssertEqual(words("statusLine", asOf: now.addingTimeInterval(-60)), "from Claude Code at 11:19")
        XCTAssertEqual(words("statusLine"), "from Claude Code")
        XCTAssertNil(words("oauth", asOf: now))
        XCTAssertNil(words("socket", asOf: now))
        XCTAssertNil(words(nil))
    }
}
