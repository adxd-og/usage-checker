import XCTest
@testable import Omelette

/// The remembered worktree links: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 3. Links are learned on the poll's agent scan, kept 366 days after last
/// use, and kept after the worktree is removed; a directory is looked up once a day, and
/// the store keeps one day of look-ups. A store on a file that does not decode starts empty.
final class WorktreeStoreVerificationTests: XCTestCase {
    private var root: URL!
    /// 2026-09-06 12:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeStoreVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var fileURL: URL { root.appendingPathComponent("worktrees.json") }

    /// `<root>/main` with a worktree `<root>/wt` linked to it.
    private func layout() throws -> (main: String, worktree: String) {
        let main = root.path + "/main"
        let gitDir = main + "/.git/worktrees/feat"
        let worktree = root.path + "/wt"
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        try "../..\n".write(toFile: gitDir + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(gitDir)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        return (main, worktree)
    }

    func testALinkIsKeptUntilTheYearAndADayAfterItsLastUseAndNotAfter() async throws {
        let (_, worktree) = try layout()
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: [worktree], now: t0)
        try FileManager.default.removeItem(atPath: worktree)

        let before = await store.links(now: t0.addingTimeInterval(366 * day - 1))
        let after = await store.links(now: t0.addingTimeInterval(366 * day + 1))
        XCTAssertEqual(before.map(\.path), [worktree], "366 days minus a second after last use")
        XCTAssertEqual(after, [], "366 days and a second after")
    }

    func testARemovedWorktreeKeepsItsFirstSightingNotTheDayItWasLookedForAndFailed() async throws {
        let (_, worktree) = try layout()
        await WorktreeStore(fileURL: fileURL).learn(paths: [worktree], now: t0)
        try FileManager.default.removeItem(atPath: worktree)

        let relaunched = WorktreeStore(fileURL: fileURL)
        await relaunched.learn(paths: [worktree], now: t0.addingTimeInterval(300 * day))
        let atThreeHundred = await relaunched.links(now: t0.addingTimeInterval(300 * day))
        XCTAssertEqual(atThreeHundred.first?.seenAt, t0, "looking for a removed worktree is not using it")

        await relaunched.learn(paths: [worktree], now: t0.addingTimeInterval(367 * day))
        let lastLaunch = await WorktreeStore(fileURL: fileURL).links(now: t0.addingTimeInterval(367 * day))
        XCTAssertEqual(lastLaunch, [], "and the file no longer holds it")
    }

    func testAWorktreeStillInUseHasItsLastUseMovedOnAtMostOnceADay() async throws {
        let (_, worktree) = try layout()
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: [worktree], now: t0)
        await store.learn(paths: [worktree], now: t0.addingTimeInterval(3_600))
        let sameDay = await store.links(now: t0.addingTimeInterval(3_600))
        XCTAssertEqual(sameDay.first?.seenAt, t0, "looked up once a day")
        await store.learn(paths: [worktree], now: t0.addingTimeInterval(day + 1))
        let nextDay = await store.links(now: t0.addingTimeInterval(day + 1))
        XCTAssertEqual(nextDay.first?.seenAt, t0.addingTimeInterval(day + 1))
    }

    func testADirectoryThatAppearsAsAWorktreeAfterAFailedLookUpIsFoundOnTheNextDay() async throws {
        let store = WorktreeStore(fileURL: fileURL)
        let worktree = root.path + "/wt"
        await store.learn(paths: [worktree], now: t0)
        let (_, created) = try layout()
        XCTAssertEqual(created, worktree)
        await store.learn(paths: [worktree], now: t0.addingTimeInterval(day - 60))
        let tooSoon = await store.links(now: t0.addingTimeInterval(day - 60))
        XCTAssertEqual(tooSoon, [], "looked up a minute short of a day ago")
        await store.learn(paths: [worktree], now: t0.addingTimeInterval(day + 60))
        let later = await store.links(now: t0.addingTimeInterval(day + 60))
        XCTAssertEqual(later.map(\.path), [worktree])
    }

    func testLookUpsOlderThanADayAreDropped() async throws {
        let (_, worktree) = try layout()
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: [worktree], now: t0)
        var known = await store.lookedUpAt
        XCTAssertEqual(known.keys.sorted(), [worktree])
        await store.learn(paths: [], now: t0.addingTimeInterval(day + 1))
        known = await store.lookedUpAt
        XCTAssertEqual(known, [:])
    }

    func testAFileThatDoesNotDecodeIsIgnoredAndWrittenOverWhenThereIsSomethingToKeep() async throws {
        try "this is not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let (main, worktree) = try layout()
        let store = WorktreeStore(fileURL: fileURL)
        let empty = await store.links(now: t0)
        XCTAssertEqual(empty, [])
        await store.learn(paths: [worktree], now: t0)
        let relaunched = await WorktreeStore(fileURL: fileURL).links(now: t0)
        XCTAssertEqual(relaunched.count, 1)
        XCTAssertTrue(relaunched.first?.main.hasSuffix("/main") ?? false, main)
    }

    func testTwoEntriesForOnePathInTheFileCountOnceWithTheNewerUse() async throws {
        let older = #"{"path":"/Users/tester/wt","main":"/Users/tester/old","seenAt":"2026-09-01T12:00:00Z"}"#
        let newer = #"{"path":"/Users/tester/wt","main":"/Users/tester/new","seenAt":"2026-09-05T12:00:00Z"}"#
        try "[\(newer),\(older)]".write(to: fileURL, atomically: true, encoding: .utf8)
        let links = await WorktreeStore(fileURL: fileURL).links(now: t0)
        XCTAssertEqual(links.map(\.main), ["/Users/tester/new"])
    }

    func testMakingAStoreDoesNotCreateItsFolderOrFile() throws {
        let folder = root.appendingPathComponent("not-yet", isDirectory: true)
        _ = WorktreeStore(fileURL: folder.appendingPathComponent("worktrees.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
