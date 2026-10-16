import XCTest
@testable import Omelette

/// Worktree folding, from layouts built by hand in a temporary directory (nothing here runs
/// `git`): spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 3.
/// A worktree's chats fold into the main repository's project slug. The lookup resolves
/// the path with realpath before walking up to a `.git`, then follows gitdir to commondir.
/// Submodules and bare repositories stay unlinked; a slug claimed by two repositories folds
/// nowhere; composed and decomposed forms of a name are both mapped.
final class ProjectWorktreesVerificationTests: XCTestCase {
    private var root: URL!
    private let seen = Date(timeIntervalSince1970: 1_788_696_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectWorktreesVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Layout builders

    private func onDisk(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `<parent>/<name>` with a `.git` directory.
    private func repository(_ name: String, in parent: String? = nil) throws -> String {
        let path = (parent ?? root.path) + "/" + name
        try mkdir(path + "/.git/worktrees")
        return path
    }

    /// A linked worktree at `path` of the repository whose git directory is `commonDir`
    /// (`<repo>/.git` or a bare repository), as `git worktree add` leaves it.
    @discardableResult
    private func worktree(
        at path: String, of commonDir: String, id: String, gitdirLine: String? = nil, commondirText: String = "../..\n"
    ) throws -> String {
        let gitDir = commonDir + "/worktrees/" + id
        try mkdir(gitDir)
        try mkdir(path)
        try write(commondirText, to: gitDir + "/commondir")
        try write(path + "/.git\n", to: gitDir + "/gitdir")
        try write(gitdirLine ?? "gitdir: \(gitDir)\n", to: path + "/.git")
        return path
    }

    // MARK: - Layouts that are not a linked worktree of a working tree

    func testAWorktreeOfABareRepositoryIsNotLinked() throws {
        let bare = root.path + "/repo.git"
        try mkdir(bare + "/worktrees")
        let wt = try worktree(at: root.path + "/wt-bare", of: bare, id: "feat")
        XCTAssertEqual(ProjectWorktrees.lookup(wt), .unlinked, "there is no main working tree to fold onto")
    }

    func testARepositoryWithItsGitDirectoryElsewhereIsNotLinked() throws {
        let gitDir = root.path + "/elsewhere.git"
        try mkdir(gitDir)
        let tree = root.path + "/separate"
        try mkdir(tree)
        try write("gitdir: \(gitDir)\n", to: tree + "/.git")
        XCTAssertEqual(ProjectWorktrees.lookup(tree), .unlinked)
    }

    func testADirectoryInsideTheMainTreeThatHoldsAWorktreeIsNotLinkedButTheWorktreeIs() throws {
        let main = try repository("main")
        try mkdir(main + "/src")
        let wt = try worktree(at: main + "/.worktrees/feat", of: main + "/.git", id: "feat")
        try mkdir(wt + "/src")
        XCTAssertEqual(ProjectWorktrees.lookup(main + "/.worktrees"), .unlinked)
        XCTAssertEqual(ProjectWorktrees.lookup(main + "/src"), .unlinked)
        XCTAssertEqual(ProjectWorktrees.lookup(wt + "/src"), .linked(main: onDisk(main) + "/src"))
        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: onDisk(main)))
    }

    // MARK: - Names and links

    func testNamesWithSpacesQuotesAndNonAsciiCharactersAreFollowed() throws {
        let main = try repository("Проект ünï \"quoted\" 日本")
        let wt = try worktree(at: root.path + "/wt ç café", of: main + "/.git", id: "feat x")
        try mkdir(wt + "/sub dir")
        XCTAssertEqual(
            ProjectWorktrees.lookup(wt + "/sub dir"), .linked(main: onDisk(main) + "/sub dir")
        )
    }

    func testAGitFileWithWindowsLineEndingsAndTrailingSpacesIsRead() throws {
        let main = try repository("main")
        let gitDir = main + "/.git/worktrees/feat"
        let wt = try worktree(
            at: root.path + "/wt", of: main + "/.git", id: "feat",
            gitdirLine: "gitdir: \(gitDir)  \r\n", commondirText: "../..\r\n"
        )
        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: onDisk(main)))
    }

    func testACommondirWrittenAbsoluteIsFollowed() throws {
        let main = try repository("main")
        let wt = try worktree(
            at: root.path + "/wt", of: main + "/.git", id: "feat", commondirText: main + "/.git\n"
        )
        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: onDisk(main)))
    }

    func testTheRepositoryReachedThroughALinkedFolderIsNamedAsTheFileSystemHasIt() throws {
        let main = try repository("real main")
        let alias = root.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: main)
        // The worktree was made through the alias: its .git file names the alias.
        let wt = try worktree(at: root.path + "/wt", of: alias + "/.git", id: "feat")
        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: onDisk(main)))
    }

    func testASymbolicLinkToTheWorktreeRootAndOneIntoTheMainTreeAreEachTheirTargets() throws {
        let main = try repository("main")
        try mkdir(main + "/src")
        let wt = try worktree(at: root.path + "/wt", of: main + "/.git", id: "feat")
        let toWorktree = root.path + "/to-wt"
        let toMain = wt + "/back-to-main"
        try FileManager.default.createSymbolicLink(atPath: toWorktree, withDestinationPath: wt)
        try FileManager.default.createSymbolicLink(atPath: toMain, withDestinationPath: main + "/src")
        XCTAssertEqual(ProjectWorktrees.lookup(toWorktree), .linked(main: onDisk(main)))
        XCTAssertEqual(ProjectWorktrees.lookup(toMain), .unlinked, "a link out of the worktree is the main tree's own folder")
    }

    func testATrailingSlashAndDotDotDoNotChangeTheAnswer() throws {
        let main = try repository("main")
        let wt = try worktree(at: root.path + "/wt", of: main + "/.git", id: "feat")
        try mkdir(wt + "/sub")
        let plain = ProjectWorktrees.lookup(wt + "/sub")
        XCTAssertEqual(plain, .linked(main: onDisk(main) + "/sub"))
        XCTAssertEqual(ProjectWorktrees.lookup(wt + "/sub/"), plain)
        XCTAssertEqual(ProjectWorktrees.lookup(wt + "/sub/../sub"), plain)
    }

    func testAFileOrAnEmptyPathIsMissing() throws {
        let file = root.path + "/note.txt"
        try write("x", to: file)
        XCTAssertEqual(ProjectWorktrees.lookup(file), .missing)
        XCTAssertEqual(ProjectWorktrees.lookup(""), .missing)
    }

    // MARK: - Folds

    func testAThirdLinkIsNotHeldBackBySlugsTwoOthersShareOnDifferentRepositories() {
        let links = [
            WorktreeLink(path: "/Users/tester/a b", main: "/Users/tester/one", seenAt: seen),
            WorktreeLink(path: "/Users/tester/a-b", main: "/Users/tester/two", seenAt: seen),
            WorktreeLink(path: "/Users/tester/solo", main: "/Users/tester/three", seenAt: seen),
        ]
        XCTAssertEqual(
            ProjectWorktrees.folds(links, serviceID: "claude"), ["-Users-tester-solo": "-Users-tester-three"]
        )
    }

    func testTheSameWorktreeSeenTwiceFoldsOnceAndAMovedRepositoryFoldsNowhere() {
        let again = [
            WorktreeLink(path: "/Users/tester/wt", main: "/Users/tester/repo", seenAt: seen),
            WorktreeLink(path: "/Users/tester/wt", main: "/Users/tester/repo", seenAt: seen.addingTimeInterval(60)),
        ]
        XCTAssertEqual(ProjectWorktrees.folds(again, serviceID: "claude"), ["-Users-tester-wt": "-Users-tester-repo"])
        let moved = [
            WorktreeLink(path: "/Users/tester/wt", main: "/Users/tester/repo", seenAt: seen),
            WorktreeLink(path: "/Users/tester/wt", main: "/Users/tester/repo-moved", seenAt: seen.addingTimeInterval(60)),
        ]
        XCTAssertEqual(ProjectWorktrees.folds(moved, serviceID: "claude"), [:], "two repositories claim the folder")
    }

    func testEveryFormOfANonAsciiNameIsMappedForBothProvidersToTheOneRepository() {
        let composed = "/Users/tester/Caf\u{E9} wt"
        let decomposed = "/Users/tester/Cafe\u{301} wt"
        let main = "/Users/tester/Caf\u{E9} repo"
        let link = [WorktreeLink(path: composed, main: main, seenAt: seen)]
        for (service, slug) in [
            ("claude", ProjectWorktrees.claudeSlug), ("codex", ProjectWorktrees.codexSlug),
        ] as [(String, (String) -> String)] {
            let folds = ProjectWorktrees.folds(link, serviceID: service)
            XCTAssertEqual(folds[slug(composed)], slug(main), service)
            XCTAssertEqual(folds[slug(decomposed)], slug(main), "\(service): the form a CLI may have been handed")
        }
    }

    // MARK: - Folding a share

    func testAFoldKeepsTheShareWhole() {
        let end = Date(timeIntervalSince1970: 1_788_696_000)
        let window = LimitWindow(start: end.addingTimeInterval(-5 * 86_400), end: end)
        let wt = "-Users-tester-wt"
        let main = "-Users-tester-main"
        var share = Fixture.limitShare(window: window, chats: [
            Fixture.chatShare(id: "chat-a", project: wt, points: 3, cost: 180, lastAt: end),
            Fixture.chatShare(id: "chat-b", project: main, points: 2, cost: 120, lastAt: end),
            Fixture.chatShare(id: "chat-c", project: "-Users-tester-other", points: 1, cost: 60, lastAt: end),
        ], outside: 1.5)
        share = LimitShare(
            window: share.window, percent: share.percent, chats: share.chats, projects: share.projects,
            outside: share.outside,
            bins: [LimitBinShare(start: window.start, delta: 7.5, chats: ["chat-a": 3, "chat-b": 2, "chat-c": 1], outside: 1.5)],
            cost: share.cost, tokens: share.tokens, price: share.price, costByModel: ["Sonnet": 360],
            unbinnedOutside: 0, earlier: nil
        )
        let folded = LimitShareRules.foldingProjects(share, into: [wt: main])
        XCTAssertEqual(folded.bins, share.bins)
        XCTAssertEqual(folded.costByModel, share.costByModel)
        XCTAssertEqual(folded.outside, share.outside)
        XCTAssertEqual(folded.cost, share.cost)
        XCTAssertEqual(folded.projects.map(\.id), [main, "-Users-tester-other"])
        XCTAssertEqual(folded.projects.first?.cost ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(folded.chats.map(\.points), share.chats.map(\.points))
        XCTAssertEqual(
            LimitShareRules.foldingProjects(share, into: ["-Users-tester-elsewhere": main]), share,
            "no chat in the folded folder: the share is returned as it is"
        )
        // A fold names its destination; it is not followed on to another fold.
        XCTAssertEqual(
            LimitShareRules.foldingProjects(share, into: [wt: main, main: "-Users-tester-other"]).chats.map(\.projectSlug),
            [main, "-Users-tester-other", "-Users-tester-other"]
        )
    }

    func testAFoldedTimelineHasOneSeriesForTheRepository() {
        let end = Date(timeIntervalSince1970: 1_788_696_000)
        let window = LimitWindow(start: end.addingTimeInterval(-3_600), end: end)
        let wt = "-Users-tester-wt"
        let main = "-Users-tester-main"
        let chats = [
            Fixture.chatShare(id: "chat-a", project: wt, points: 3, cost: 180, lastAt: end),
            Fixture.chatShare(id: "chat-b", project: main, points: 2, cost: 120, lastAt: end),
        ]
        let share = LimitShare(
            window: window, percent: 5, chats: chats, projects: LimitShareRules.projectShares(chats), outside: 0,
            bins: [LimitBinShare(start: window.start, delta: 5, chats: ["chat-a": 3, "chat-b": 2], outside: 0)],
            cost: 300, tokens: 2_000, price: nil, costByModel: [:], unbinnedOutside: 0, earlier: nil
        )
        func series(_ share: LimitShare) -> [String] {
            LimitsRules.timeline(of: share, serviceID: "claude", projectName: { $1 }).series.map(\.id)
        }
        XCTAssertEqual(series(share), [wt, main])
        XCTAssertEqual(series(LimitShareRules.foldingProjects(share, into: [wt: main])), [main])
    }
}
