import XCTest
@testable import Omelette

/// The worktrees a session ran in, remembered: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 3, on the owner's
/// request of 2026-10-16. A worktree is looked up while it is on disk; its link must
/// outlive `git worktree remove`, go when the path is something else now, and go a year
/// after its last use. Each store points at a temp file; a new store on the same file is a
/// relaunch.
final class WorktreeStoreTests: XCTestCase {
    private var root: URL!
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var fileURL: URL { root.appendingPathComponent("worktrees.json") }

    func testAWorktreeASessionRanInIsRememberedAfterItIsRemoved() async throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        let main = Fixture.onDisk(repo.path)
        await WorktreeStore(fileURL: fileURL).learn(paths: [worktree.path], now: now)

        try FileManager.default.removeItem(at: worktree)
        let relaunched = WorktreeStore(fileURL: fileURL)
        await relaunched.learn(paths: [worktree.path], now: now.addingTimeInterval(2 * day))
        let links = await relaunched.links(now: now.addingTimeInterval(2 * day))

        XCTAssertEqual(links, [WorktreeLink(path: worktree.path, main: main, seenAt: now)])
    }

    func testADirectoryThatIsNoLongerAWorktreeIsForgotten() async throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: [worktree.path], now: now)

        // The same path, a plain directory now.
        try FileManager.default.removeItem(at: worktree.appendingPathComponent(".git"))
        await store.learn(paths: [worktree.path], now: now.addingTimeInterval(2 * day))

        let links = await store.links(now: now.addingTimeInterval(2 * day))
        XCTAssertEqual(links, [])
        let relaunched = await WorktreeStore(fileURL: fileURL).links(now: now.addingTimeInterval(2 * day))
        XCTAssertEqual(relaunched, [], "and the file says so")
    }

    func testADirectoryIsLookedUpAtMostOnceADay() async throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: [worktree.path], now: now)
        try FileManager.default.removeItem(at: worktree.appendingPathComponent(".git"))

        await store.learn(paths: [worktree.path], now: now.addingTimeInterval(23 * 3_600))
        let sameDay = await store.links(now: now.addingTimeInterval(23 * 3_600))
        XCTAssertEqual(sameDay.map(\.path), [worktree.path], "not looked up again within a day")

        await store.learn(paths: [worktree.path], now: now.addingTimeInterval(24 * 3_600))
        let nextDay = await store.links(now: now.addingTimeInterval(24 * 3_600))
        XCTAssertEqual(nextDay, [])
    }

    func testOnlyTheLastDaysLookUpsAreRemembered() async throws {
        let plain = try (0..<3).map { index -> String in
            let folder = root.appendingPathComponent("notes-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.path
        }
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: plain + [root.appendingPathComponent("gone").path], now: now)
        let sameDay = await store.lookedUpAt
        XCTAssertEqual(sameDay.count, 4)

        await store.learn(paths: [plain[0]], now: now.addingTimeInterval(25 * 3_600))
        let nextDay = await store.lookedUpAt
        XCTAssertEqual(Set(nextDay.keys), [plain[0]], "a day on, the others are forgotten until a session runs there again")
    }

    func testALinkNoSessionUsedForAYearIsForgotten() async throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        let store = WorktreeStore(fileURL: fileURL)
        await store.learn(paths: [worktree.path], now: now)

        let withinAYear = await store.links(now: now.addingTimeInterval(365 * day))
        XCTAssertEqual(withinAYear.count, 1)
        let afterAYear = await store.links(now: now.addingTimeInterval(366 * day))
        XCTAssertEqual(afterAYear, [])
    }

    func testTheMainWorkingTreeAPlainDirectoryAndAMissingOneAreNotKept() async throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let plain = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        await WorktreeStore(fileURL: fileURL).learn(
            paths: [repo.path, plain.path, root.appendingPathComponent("gone").path], now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "nothing to keep, nothing written")
        let links = await WorktreeStore(fileURL: fileURL).links(now: now)
        XCTAssertEqual(links, [])
    }

    func testMakingAStoreTouchesNoDiskAndSavingMakesItsFolder() async throws {
        let folder = root.appendingPathComponent("Application Support/UsageTracker", isDirectory: true)
        let store = WorktreeStore(fileURL: folder.appendingPathComponent("worktrees.json"))
        let none = await store.links(now: now)
        XCTAssertEqual(none, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "made and read, the store created nothing")

        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        await store.learn(paths: [worktree.path], now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("worktrees.json").path))
    }
}
