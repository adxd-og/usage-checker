import XCTest
@testable import Omelette

/// A chat's stretches as rows: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 5 ("Each stretch shows its time range, its share and dollars, its
/// cold-start cost …, and as its name the first human prompt after the boundary"). Only the
/// chats that are open are formatted: a month can hold thousands of stretches.
final class LimitsStretchRowsTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private func at(_ text: String) -> Date { Self.iso.date(from: text) ?? .distantPast }

    private func stretch(
        _ opening: StretchOpening, from: String, to: String, points: Double, cost: Double,
        coldStart: Double = 0, prompt: String?
    ) -> ChatStretch {
        ChatStretch(
            opening: opening, firstAt: at(from), lastAt: at(to), points: points, cost: cost,
            coldStartCost: coldStart, prompt: prompt
        )
    }

    /// The rows of `chat`, open, when chat A has `stretches`.
    private func rows(_ stretches: [ChatStretch], chat: String = "chat-a") -> [LimitsRow] {
        LimitsRules.stretchRows(
            chatIDs: [chat], stretches: ["chat-a": stretches], now: now, calendar: calendar, locale: locale
        )[chat] ?? []
    }

    func testAStretchRowCarriesItsPromptHoursShareAndDollars() {
        XCTAssertEqual(
            rows([stretch(.firstTurn, from: "2026-09-05T10:40:00Z", to: "2026-09-05T12:15:00Z",
                          points: 2.5, cost: 155, coldStart: 0.3, prompt: "Fix the flaky reset test")]),
            [LimitsRow(
                id: "chat-a#0", title: "Fix the flaky reset test",
                subtitle: "Sat 10:40–12:15 · cold start $0.30", share: "≈ 2.5 %", dollars: "$155"
            )]
        )
    }

    func testAStretchNoPromptWasTypedForSaysSo() {
        let row = rows([stretch(.coldStart, from: "2026-09-05T13:00:00Z", to: "2026-09-05T14:20:00Z",
                                points: 0.04, cost: 3.1, prompt: nil)]).first
        XCTAssertEqual(row?.title, "No prompt in this stretch")
        XCTAssertEqual(row?.share, "< 0.1 %")
        XCTAssertEqual(row?.dollars, "$3.10")
    }

    func testHowAStretchBeganAndWhatItsColdStartCostAreInItsSubtitle() {
        let subtitles = rows([
            stretch(.compaction, from: "2026-09-05T13:00:00Z", to: "2026-09-05T14:20:00Z",
                    points: 1, cost: 62, prompt: "Now the changelog"),
            stretch(.coldStart, from: "2026-09-05T16:00:00Z", to: "2026-09-05T17:10:00Z",
                    points: 1, cost: 62, coldStart: 1.2, prompt: "After lunch"),
            stretch(.compaction, from: "2026-09-05T18:00:00Z", to: "2026-09-05T19:00:00Z",
                    points: 1, cost: 62, coldStart: 0.004, prompt: "Then the appcast"),
        ]).map(\.subtitle)
        XCTAssertEqual(subtitles, [
            "Sat 13:00–14:20 · after a compaction",
            "Sat 16:00–17:10 · cold start $1.20",
            "Sat 18:00–19:00 · after a compaction",
        ], "a cold start under half a cent is not worth a word")
    }

    func testAStretchOfOneTurnNamesOneTime() {
        XCTAssertEqual(
            rows([stretch(.coldStart, from: "2026-09-05T14:20:00Z", to: "2026-09-05T14:20:00Z",
                          points: 0.5, cost: 30, prompt: "One question")]).first?.subtitle,
            "Sat 14:20"
        )
    }

    func testAChatTheLoadHasNoStretchesForHasNoRows() {
        XCTAssertEqual(rows([], chat: "chat-b"), [])
    }

    func testOnlyTheOpenChatsAreFormatted() {
        let one = stretch(.firstTurn, from: "2026-09-05T10:40:00Z", to: "2026-09-05T12:15:00Z",
                          points: 1, cost: 62, prompt: "Fix the flaky reset test")
        let rows = LimitsRules.stretchRows(
            chatIDs: ["chat-a", "chat-c"], stretches: ["chat-a": [one], "chat-b": [one]],
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(Set(rows.keys), ["chat-a"], "chat B is closed, and chat C has no stretch")
    }

    func testTheChevronSaysShowOrHideStretches() {
        XCTAssertEqual(LimitsCopy.stretchToggle(expanded: false), "Show stretches")
        XCTAssertEqual(LimitsCopy.stretchToggle(expanded: true), "Hide stretches")
    }
}
