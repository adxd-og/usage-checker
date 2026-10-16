import XCTest
@testable import Omelette

/// Invariants the Limits tab's history must keep whatever the readings and turns look like,
/// over a few hundred generated histories (a fixed seed, so a failure reproduces): spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds and
/// Totals, and § The tab, items 1 and 5.
/// - the past windows are newest first, never overlap, lie between the horizon and the open
///   window, and are one per session when every reading names its reset;
/// - a chat's stretches add up to its points and its dollars, and never overlap.
final class LimitHistoryInvariantsVerificationTests: XCTestCase {
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let base = Date(timeIntervalSince1970: 1_788_688_800) // 2026-09-06 10:00 UTC

    /// A small deterministic generator (SplitMix64).
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
        mutating func chance(_ percent: Int) -> Bool { int(1...100) <= percent }
    }

    // MARK: - Past windows

    func testPastWindowsOfGeneratedSessionHistoriesStayOrderedApartAndOnePerSession() {
        for seed in 1...300 {
            var random = Seeded(state: UInt64(seed))
            let sessionCount = random.int(2...9)
            var cursor = base
            var points: [(at: Date, percent: Double, resetsAt: Date)] = []
            var expected: [(start: Date, end: Date)] = []
            var lastStart = cursor
            var lastRan = 5.0
            for index in 0..<sessionCount {
                // Some idle time before a session that follows a full one.
                if index > 0, lastRan == 5, random.chance(40) {
                    let idle = Double(random.int(2...6)) * 30 * minute
                    var at = cursor + 15 * minute
                    while at < cursor + idle {
                        points.append((at: at, percent: 0, resetsAt: .distantFuture))
                        at += 30 * minute
                    }
                    cursor += idle
                }
                let start = cursor
                let reset = start + 5 * hour
                // A session runs a whole number of quarter hours; cut short means an early reset.
                let ran = random.chance(35) ? Double(random.int(2...19)) / 4 : 5
                let stop = start + ran * hour
                var percent = 1.0
                var at = start + 7 * minute
                while at < stop - minute {
                    // The reset a reading reports wanders by a second or two.
                    let jitter = Double(random.int(-2...2))
                    points.append((at: at, percent: percent, resetsAt: reset + jitter))
                    percent += Double(random.int(0...3))
                    at += Double(random.int(10...25)) * minute
                }
                if index < sessionCount - 1 {
                    expected.append((start: start, end: stop))
                }
                lastStart = start
                lastRan = ran
                cursor = stop
            }
            let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: points)
            let result = LimitShareRules.pastWindows(
                records: records, bucketID: "five_hour", windowLength: 5 * hour, before: lastStart,
                horizonStart: base - hour
            )
            // A session whose readings never left 0 is idle time, not a window.
            let listed = result.map { (start: $0.start, end: $0.end) }
            XCTAssertEqual(listed.count <= expected.count, true, "seed \(seed)")
            for (newer, older) in zip(result, result.dropFirst()) {
                XCTAssertLessThanOrEqual(older.end, newer.start, "seed \(seed): windows overlap")
            }
            for window in result {
                XCTAssertLessThan(window.start, window.end, "seed \(seed)")
                XCTAssertLessThanOrEqual(window.end, lastStart, "seed \(seed): a window past the open one")
                XCTAssertGreaterThanOrEqual(window.start, base - hour, "seed \(seed)")
                if let resets = window.resets { XCTAssertLessThanOrEqual(resets.lowerBound, resets.upperBound) }
            }
            // Every session that left 0 is found, once, with the span it ran.
            let ones = expected.filter { span in
                points.contains { $0.at > span.start && $0.at <= span.end && $0.percent > 0 }
            }
            XCTAssertEqual(listed.count, ones.count, "seed \(seed): one window per session")
            // The reset each reading reports wanders by up to two seconds.
            for (found, session) in zip(listed, ones.reversed()) {
                XCTAssertEqual(found.start.timeIntervalSince1970, session.start.timeIntervalSince1970, accuracy: 2.5, "seed \(seed): starts with the session")
                XCTAssertEqual(found.end.timeIntervalSince1970, session.end.timeIntervalSince1970, accuracy: 2.5, "seed \(seed): ends where the session ended")
            }
        }
    }

    func testPastWindowsOfHistoriesWithSomeReadingsThatNamedNoResetStayOrderedAndApart() {
        for seed in 1...300 {
            var random = Seeded(state: UInt64(seed) &* 7919)
            var cursor = base
            var records: [HistoryRecord] = []
            var lastStart = cursor
            for _ in 0..<random.int(2...8) {
                let start = cursor
                let reset = start + 5 * hour
                let stop = start + (random.chance(30) ? Double(random.int(2...19)) / 4 : 5) * hour
                var percent = Double(random.int(1...3))
                var at = start + 7 * minute
                // An older build wrote this run: no reset in it.
                let reportsReset = random.chance(60)
                while at < stop - minute {
                    if reportsReset {
                        records += Fixture.timedReadings(
                            bucketID: "five_hour", kind: .session, points: [(at: at, percent: percent, resetsAt: reset)]
                        )
                    } else {
                        records += Fixture.readings(bucketID: "five_hour", points: [(at: at, percent: percent)])
                    }
                    percent += Double(random.int(0...4))
                    at += Double(random.int(10...25)) * minute
                }
                lastStart = start
                cursor = stop
            }
            let result = LimitShareRules.pastWindows(
                records: records, bucketID: "five_hour", windowLength: 5 * hour, before: lastStart,
                horizonStart: base - hour
            )
            for (newer, older) in zip(result, result.dropFirst()) {
                XCTAssertLessThanOrEqual(older.end, newer.start, "seed \(seed): windows overlap")
            }
            for window in result {
                XCTAssertLessThan(window.start, window.end, "seed \(seed)")
                XCTAssertLessThanOrEqual(window.end, lastStart, "seed \(seed): a window past the open one")
            }
        }
    }

    // MARK: - Stretches

    func testStretchesOfGeneratedChatsAddUpToTheChatsAndNeverOverlap() throws {
        let window = LimitWindow(start: base, end: base + 10 * hour)
        for seed in 1...300 {
            var random = Seeded(state: UInt64(seed) &* 104_729)
            var turns: [TurnCost] = []
            var compactions: [String: [Date]] = [:]
            for chat in ["chat-a", "chat-b", "chat-c"] {
                var at = base + Double(random.int(0...90)) * minute
                for _ in 0..<random.int(1...14) {
                    let isMain = !random.chance(25)
                    let isCold = isMain && random.chance(25)
                    turns.append(Fixture.promptTurn(
                        at: at, chat: chat, input: random.int(1...5_000),
                        cacheRead: isCold ? 0 : random.int(0...200_000), cacheWrite1h: isCold ? random.int(10_000...60_000) : random.int(0...2_000),
                        output: random.int(0...3_000), isMainThread: isMain
                    ))
                    at += Double(random.int(1...70)) * minute
                }
                if random.chance(50) { compactions[chat] = [base + Double(random.int(30...500)) * minute] }
            }
            var readings: [LimitReading] = []
            var percent = 0.0
            var at = base + Double(random.int(5...40)) * minute
            while at < window.end {
                percent = min(100, percent + Double(random.int(0...4)))
                readings.append(LimitReading(time: at, percent: percent))
                at += Double(random.int(5...50)) * minute
            }
            let log = TurnCostLog(turns: turns.sorted { $0.timestamp < $1.timestamp }, compactions: compactions)
            let share = LimitShareRules.share(window: window, series: readings, log: log)
            let all = LimitShareRules.stretches(of: share, log: log, serviceID: "claude")
            for chat in share.chats {
                let cut = try XCTUnwrap(all[chat.id], "seed \(seed) \(chat.id)")
                XCTAssertEqual(cut.reduce(0) { $0 + $1.points }, chat.points, accuracy: 1e-8, "seed \(seed) \(chat.id): points")
                XCTAssertEqual(cut.reduce(0) { $0 + $1.cost }, chat.cost, accuracy: 1e-8, "seed \(seed) \(chat.id): dollars")
                XCTAssertEqual(cut.first?.opening, .firstTurn, "seed \(seed)")
                XCTAssertEqual(cut.dropFirst().filter { $0.opening == .firstTurn }.count, 0, "seed \(seed)")
                for (before, after) in zip(cut, cut.dropFirst()) {
                    XCTAssertLessThanOrEqual(before.lastAt, after.firstAt, "seed \(seed) \(chat.id): overlap")
                }
                for stretch in cut {
                    XCTAssertLessThanOrEqual(stretch.coldStartCost, stretch.cost + 1e-9, "seed \(seed)")
                    XCTAssertGreaterThanOrEqual(stretch.points, -1e-12, "seed \(seed)")
                }
            }
        }
    }
}
