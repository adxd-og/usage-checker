import XCTest
@testable import Omelette

/// Independent verification of `PassiveSessionScanner.codexPartitionIsRecent` and the
/// end-to-end `scan()` it gates, derived from
/// `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)", item 3, not from `PassiveSessionScannerTests`. Focus: a day
/// directory is walked "whatever its date" — including a day whose *year* is long
/// over — because only year and month are judged; and month pruning still holds at a
/// year boundary, where a date-arithmetic slip is easiest to hide.
final class PassiveSessionScannerVerificationTests: XCTestCase {
    private var root: URL!
    private var codexRoot: URL!
    private let now = Date(timeIntervalSince1970: 1_820_000_000)
    private let sessionID = "37384099-5d4f-423d-ae8b-0eb0c3308aae"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassiveScanVerificationTests-\(UUID().uuidString)", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("claude-projects", isDirectory: true), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ contents: String, to relativePath: String, secondsAgo: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path
        )
        return url
    }

    private func rollout(cwd: String, id: String) -> String {
        """
        {"timestamp":"2026-08-06T11:30:14.849Z","type":"session_meta","payload":{"session_id":"\(id)","id":"\(id)","cwd":"\(cwd)"}}
        {"timestamp":"2026-08-06T11:30:14.849Z","type":"event_msg","payload":{"type":"task_started"}}

        """
    }

    private func scan() -> [AgentSession] {
        PassiveSessionScanner.scan(
            claudeProjects: root.appendingPathComponent("claude-projects", isDirectory: true),
            codexSessions: codexRoot, now: now
        )
    }

    // MARK: - A day directory is walked whatever its date

    /// The current month is inside the window; a day directory under it names a date
    /// well over a year old (a clock mistake, a restored backup — whatever the cause).
    /// Only year/month are judged, so this stale-looking day directory must still be
    /// entered, and its fresh file scanned.
    func testADayUnderTheCurrentMonthIsWalkedEvenWhenItsOwnDateIsOverAYearOld() throws {
        let currentMonth = Calendar.current.dateComponents([.year, .month], from: now)
        let bogusDay = String(format: "%04d/%02d/01", (currentMonth.year ?? 2026), currentMonth.month ?? 1)
        try write(
            rollout(cwd: "/Users/tester/Projects/beta", id: sessionID),
            to: "codex-sessions/\(bogusDay)/rollout-2024-01-01T00-00-00-\(sessionID).jsonl",
            secondsAgo: 5
        )

        let sessions = scan()
        XCTAssertEqual(sessions.map(\.id), ["codex:\(sessionID)"])
        XCTAssertEqual(sessions.first?.state, .working)
    }

    /// Directly against the pure rule: a day-level path is always "recent" regardless
    /// of the day number, including an out-of-range one no calendar could parse.
    func testCodexPartitionIsRecentNeverPrunesADayLevelPath() {
        let calendar = Calendar(identifier: .gregorian)
        let sessionsRoot = URL(fileURLWithPath: "/Users/tester/.codex/sessions", isDirectory: true)
        func isRecent(_ relative: String) -> Bool {
            PassiveSessionScanner.codexPartitionIsRecent(
                URL(fileURLWithPath: sessionsRoot.path + "/" + relative, isDirectory: true),
                root: sessionsRoot, cutoff: now, calendar: calendar
            )
        }
        XCTAssertTrue(isRecent("2019/01/01"), "a day three years before the cutoff's year")
        XCTAssertTrue(isRecent("2019/01/99"), "not even a valid day number")
        XCTAssertTrue(isRecent("2019/13/01"), "not even a valid month, but three components deep")
    }

    // MARK: - Month pruning still holds across a year boundary

    /// The cutoff sits half a day after New Year's Day. December of the *previous*
    /// year ended exactly at 2027-01-01 00:00, which is inside the one-day slack —
    /// recent. November of the previous year ended 2026-12-01, well outside it —
    /// pruned. Because December is the year's last month, "2026" the *year* ends at
    /// the same instant as "2026/12" and is recent for the same reason.
    func testMonthPruningIsCorrectAcrossANewYearBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let cutoff = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12))!
        let sessionsRoot = URL(fileURLWithPath: "/Users/tester/.codex/sessions", isDirectory: true)
        func isRecent(_ relative: String) -> Bool {
            PassiveSessionScanner.codexPartitionIsRecent(
                URL(fileURLWithPath: sessionsRoot.path + "/" + relative, isDirectory: true),
                root: sessionsRoot, cutoff: cutoff, calendar: calendar
            )
        }
        XCTAssertTrue(isRecent("2027"), "the new year has barely started")
        XCTAssertTrue(isRecent("2026/12"), "ended 2027-01-01 00:00, inside the day of slack")
        XCTAssertFalse(isRecent("2026/11"), "ended 2026-12-01, more than a month before the cutoff")
        XCTAssertTrue(isRecent("2026"), "the year 2026 ends at the same instant as its last month, 2026/12")
    }

    /// Months later, the whole of 2026 (year and every month in it) is finally
    /// outside the window.
    func testAWholeYearIsPrunedOnceItIsFarEnoughBehind() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let cutoff = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1))!
        let sessionsRoot = URL(fileURLWithPath: "/Users/tester/.codex/sessions", isDirectory: true)
        func isRecent(_ relative: String) -> Bool {
            PassiveSessionScanner.codexPartitionIsRecent(
                URL(fileURLWithPath: sessionsRoot.path + "/" + relative, isDirectory: true),
                root: sessionsRoot, cutoff: cutoff, calendar: calendar
            )
        }
        XCTAssertFalse(isRecent("2026"))
        XCTAssertFalse(isRecent("2026/12"))
        XCTAssertTrue(isRecent("2027"))
    }

    /// A rollout that lives under an earlier month's day directory is pruned before
    /// any file inside it is even looked at, however fresh that file's own mtime is —
    /// the month gate runs at directory-descent time.
    func testAFreshFileUnderAPrunedMonthIsNeverReached() throws {
        let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: now)!
        let components = Calendar.current.dateComponents([.year, .month], from: twoMonthsAgo)
        let path = String(format: "%04d/%02d/15", components.year ?? 0, components.month ?? 0)
        try write(
            rollout(cwd: "/Users/tester/Projects/beta", id: sessionID),
            to: "codex-sessions/\(path)/rollout-2026-01-15T00-00-00-\(sessionID).jsonl",
            secondsAgo: 1 // written a second ago -- would read as "working" if it were ever reached
        )

        XCTAssertTrue(scan().isEmpty, "the month is pruned before the file's own fresh mtime can matter")
    }
}
