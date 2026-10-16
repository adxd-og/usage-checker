import Foundation
@testable import Omelette

/// History records around limit resets, copied from this Mac's history log
/// (`history.jsonl` in the app's Application Support folder, read 2026-10-16) with the
/// ids replaced and the windows the Limits tab does not measure left out. Each line is
/// decoded the way `HistoryStore` decodes its log, so each record is a real
/// `HistoryRecord`.
enum LimitHistoryFixture {
    /// `HistoryStore`'s decoder: ISO 8601 dates.
    static func records(_ lines: [String]) throws -> [HistoryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines.map { try decoder.decode(HistoryRecord.self, from: Data($0.utf8)) }
    }

    /// 2026-10-05, Claude Max: a session that never reached 5 % ends at 11:30 and the next
    /// one opens at once. The percent falls 2 → 0, too little for a drop to tell. Every
    /// reading names its session's reset: 11:30 (11:29:59 once), `4001-01-01`
    /// (`Date.distantFuture`) while no session is open, then 16:30.
    static let sessionEndingAtTwoPercent = [
        #"{"id":"6F1C2A10-0000-4000-8000-000000001001","timestamp":"2026-10-05T10:04:46Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":2,"seven_day":86},"fiveHourPercent":2,"fiveHourResetsAt":"2026-10-05T11:30:00Z","sevenDayPercent":86,"sevenDayResetsAt":"2026-10-08T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000001002","timestamp":"2026-10-05T11:28:30Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":2,"seven_day":86},"fiveHourPercent":2,"fiveHourResetsAt":"2026-10-05T11:30:00Z","sevenDayPercent":86,"sevenDayResetsAt":"2026-10-08T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000001003","timestamp":"2026-10-05T11:29:51Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":2,"seven_day":86},"fiveHourPercent":2,"fiveHourResetsAt":"2026-10-05T11:29:59Z","sevenDayPercent":86,"sevenDayResetsAt":"2026-10-08T09:59:59Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000001004","timestamp":"2026-10-05T11:30:53Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":0,"seven_day":86},"fiveHourPercent":0,"fiveHourResetsAt":"4001-01-01T00:00:00Z","sevenDayPercent":86,"sevenDayResetsAt":"2026-10-08T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000001005","timestamp":"2026-10-05T11:31:55Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":0,"seven_day":86},"fiveHourPercent":0,"fiveHourResetsAt":"2026-10-05T16:30:00Z","sevenDayPercent":86,"sevenDayResetsAt":"2026-10-08T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000001006","timestamp":"2026-10-05T11:43:13Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":1,"seven_day":86},"fiveHourPercent":1,"fiveHourResetsAt":"2026-10-05T16:30:00Z","sevenDayPercent":86,"sevenDayResetsAt":"2026-10-08T10:00:00Z","extraCreditsUsed":0}"#,
    ]

    /// 2026-10-12, Claude Max, 13:20: the session at 99 % (reset 15:00) gives way to one
    /// that resets at 18:20, while the week falls 60 → 51 and keeps its reset, 2026-10-15
    /// 10:00 (a limit restored mid-week). The 99 % reading is stamped 13:20:07, seven
    /// seconds after its session ended.
    static let restoreAndEarlyReset = [
        #"{"id":"6F1C2A10-0000-4000-8000-000000002001","timestamp":"2026-10-12T13:19:33Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":97,"seven_day":59},"fiveHourPercent":97,"fiveHourResetsAt":"2026-10-12T15:00:00Z","sevenDayPercent":59,"sevenDayResetsAt":"2026-10-15T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000002002","timestamp":"2026-10-12T13:20:07Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":99,"seven_day":60},"fiveHourPercent":99,"fiveHourResetsAt":"2026-10-12T15:00:00Z","sevenDayPercent":60,"sevenDayResetsAt":"2026-10-15T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000002003","timestamp":"2026-10-12T13:20:42Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":0,"seven_day":51},"fiveHourPercent":0,"fiveHourResetsAt":"2026-10-12T18:20:00Z","sevenDayPercent":51,"sevenDayResetsAt":"2026-10-15T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000002004","timestamp":"2026-10-12T13:21:37Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":0,"seven_day":51},"fiveHourPercent":0,"fiveHourResetsAt":"2026-10-12T18:20:00Z","sevenDayPercent":51,"sevenDayResetsAt":"2026-10-15T10:00:00Z","extraCreditsUsed":0}"#,
        #"{"id":"6F1C2A10-0000-4000-8000-000000002005","timestamp":"2026-10-12T14:58:23Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":15,"seven_day":55},"fiveHourPercent":15,"fiveHourResetsAt":"2026-10-12T18:20:00Z","sevenDayPercent":55,"sevenDayResetsAt":"2026-10-15T10:00:00Z","extraCreditsUsed":0}"#,
    ]

    /// Codex Prolite's weekly readings 2026-10-12 to 10-15, written before records kept a
    /// reset time: two drops to 0 (5 → 0 overnight, 6 → 0 the next night).
    static let codexBeforeResetTimes = [
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003001","timestamp":"2026-10-12T22:06:41Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":5}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003002","timestamp":"2026-10-12T22:07:44Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":5}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003003","timestamp":"2026-10-13T07:26:18Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":0}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003004","timestamp":"2026-10-13T07:26:57Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":0}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003005","timestamp":"2026-10-14T18:35:35Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":6}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003006","timestamp":"2026-10-14T18:36:37Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":6}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003007","timestamp":"2026-10-15T06:22:29Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":0}}"#,
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003008","timestamp":"2026-10-15T06:23:26Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":0}}"#,
    ]

    /// The next Codex reading, 2026-10-16 13:33, in the shape records take from this
    /// release on: with the reset Codex's own rollout reported for that week, and the
    /// week's length.
    static let codexAfterResetTimes = [
        #"{"serviceID":"codex","id":"6F1C2A10-0000-4000-8000-000000003009","timestamp":"2026-10-16T13:33:23Z","plan":"Codex Prolite","bucketPercents":{"codex_weekly":19},"bucketWindows":{"codex_weekly":{"resetsAt":"2026-10-22T13:00:48Z","length":604800}}}"#,
    ]
}

/// Builders for the Limits tab's history (spec 2026-10-16 limit analytics § Design, Window
/// bounds; § The tab, item 5): readings that name their reset, and turns whose prompt is
/// split into fresh input, cache read and cache write.
extension Fixture {
    /// One bucket's readings with the reset each one reported, as a provider's snapshot
    /// hands them to `HistoryRecord(from:at:)`. `windowLength` is the length the bucket
    /// states; without one the bucket's kind implies it.
    static func timedReadings(
        service: String = "claude",
        bucketID: String,
        kind: BucketKind,
        windowLength: TimeInterval? = nil,
        points: [(at: Date, percent: Double, resetsAt: Date)]
    ) -> [HistoryRecord] {
        points.map { point in
            HistoryRecord(
                from: snapshot(id: service, buckets: [
                    bucket(
                        id: bucketID, percent: point.percent, resetsAt: point.resetsAt, kind: kind,
                        windowLength: windowLength
                    ),
                ]),
                at: point.at
            )
        }
    }

    /// Sonnet's list prices per million tokens: $3 input, $15 output, $0.30 cache read,
    /// $3.75 and $6 for the 5-minute and 1-hour cache writes.
    static let sonnetPrice = ModelPrice(
        inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6
    )

    /// One turn with its prompt split the way the logs split it, priced at `sonnetPrice`
    /// as `TokenBreakdown.priced(with:)` prices a turn, so its dollars are its tokens'.
    static func promptTurn(
        at date: Date,
        chat: String,
        project: String = "-Users-tester-Projects-alpha",
        input: Int = 0,
        cacheRead: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        output: Int = 0,
        isMainThread: Bool = true
    ) -> TurnCost {
        let tokens = TokenBreakdown(
            input: input, output: output, cacheRead: cacheRead,
            cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h
        ).priced(with: sonnetPrice)
        return TurnCost(
            timestamp: date, chatID: chat, projectSlug: project, model: "claude-sonnet-4-5",
            tokens: tokens, cost: tokens.cost?.total ?? 0, isMainThread: isMainThread
        )
    }
}
