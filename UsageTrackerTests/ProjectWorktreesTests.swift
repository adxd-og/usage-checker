import XCTest
@testable import Omelette

/// Where a git worktree's chats belong: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 3 (a project's row sums its chats), on the owner's request of 2026-10-16:
/// a chat run in a worktree counts under the repository the worktree belongs to, in
/// Projects, in Chats and on the timeline. The layouts are the ones `git worktree add`
/// leaves, built in a temporary directory per test. Paths the lookup returns are as the
/// file system has them (`realpath(3)`): the temp folder's `/var` is `/private/var` there.
final class ProjectWorktreesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectWorktreesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The lookup

    func testADirectoryInAWorktreeIsTheSameDirectoryInTheMainWorkingTree() throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        XCTAssertEqual(ProjectWorktrees.lookup(worktree.path), .linked(main: Fixture.onDisk(repo.path)))
        XCTAssertEqual(
            ProjectWorktrees.lookup(worktree.appendingPathComponent("Sources").path),
            .linked(main: Fixture.onDisk(repo.path) + "/Sources")
        )
    }

    func testAGitdirWrittenRelativeIsReadFromTheWorktree() throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(
            named: "usage-tracker-wt-published", id: "published", of: repo, in: root, relative: true
        )
        XCTAssertEqual(ProjectWorktrees.lookup(worktree.path), .linked(main: Fixture.onDisk(repo.path)))
    }

    func testADirectoryReachedThroughASymbolicLinkIsTheWorktreesOwn() throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        let worktree = try Fixture.gitWorktree(named: "usage-tracker-wt-tab", id: "tab", of: repo, in: root)
        let link = root.appendingPathComponent("sources-link").path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: worktree.appendingPathComponent("Sources").path
        )
        XCTAssertEqual(
            ProjectWorktrees.lookup(link), .linked(main: Fixture.onDisk(repo.path) + "/Sources"),
            "the link is followed before the parents are walked: none of the link's own parents holds a .git"
        )
    }

    func testTheMainWorkingTreeASubmoduleAndAPlainDirectoryAreNotLinked() throws {
        let repo = try Fixture.gitRepository(named: "Usage tracker", in: root)
        XCTAssertEqual(ProjectWorktrees.lookup(repo.path), .unlinked, "its .git is a directory")

        // A submodule's .git file names a git directory with no commondir.
        let module = repo.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git/modules/lib", isDirectory: true), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/lib\n".write(
            to: module.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(ProjectWorktrees.lookup(module.path), .unlinked)

        let plain = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectWorktrees.lookup(plain.path), .unlinked)
    }

    func testARemovedWorktreeIsMissing() {
        XCTAssertEqual(ProjectWorktrees.lookup(root.appendingPathComponent("usage-tracker-wt-gone").path), .missing)
        XCTAssertEqual(ProjectWorktrees.lookup("Projects/alpha"), .missing, "not an absolute path")
    }

    func testComposedAndDecomposedNamesFoldOntoTheRepositoryAsItsLogsNameIt() throws {
        // Both folders made as typed, composed, the form `getcwd` and so both CLIs give.
        let repoPath = try Fixture.directoryAsTyped("R\u{E9}sum\u{E9}", in: root)
        let repo = try Fixture.gitRepository(named: "R\u{E9}sum\u{E9}", in: root)
        let composed = try Fixture.directoryAsTyped("wt-Caf\u{E9}", in: root)
        _ = try Fixture.gitWorktree(named: "wt-Caf\u{E9}", id: "cafe", of: repo, in: root)
        let decomposed = root.path + "/wt-Cafe\u{301}"

        guard case .linked(let fromComposed) = ProjectWorktrees.lookup(composed),
              case .linked(let fromDecomposed) = ProjectWorktrees.lookup(decomposed)
        else { return XCTFail("the worktree is found by either form of its name") }
        // Two strings in different forms compare equal in Swift; their slugs do not, so
        // the slugs are what is compared.
        let logged = ProjectWorktrees.claudeSlug(Fixture.onDisk(repoPath))
        XCTAssertTrue(logged.hasSuffix("-R-sum-"), "the repository's name as stored: composed")
        XCTAssertEqual(ProjectWorktrees.claudeSlug(fromComposed), logged)
        XCTAssertEqual(ProjectWorktrees.claudeSlug(fromDecomposed), logged)

        // The two forms are two Claude project folders; the worktree is folded as both.
        XCTAssertNotEqual(ProjectWorktrees.claudeSlug(composed), ProjectWorktrees.claudeSlug(decomposed))
        let seen = Date(timeIntervalSince1970: 1_788_696_000)
        for serviceID in ["claude", "codex"] {
            let slug: (String) -> String = { serviceID == "claude" ? ProjectWorktrees.claudeSlug($0) : ProjectWorktrees.codexSlug($0) }
            let folds = ProjectWorktrees.folds(
                [WorktreeLink(path: composed, main: fromComposed, seenAt: seen)], serviceID: serviceID
            )
            XCTAssertEqual(folds[slug(composed)], slug(Fixture.onDisk(repoPath)), serviceID)
            XCTAssertEqual(folds[slug(decomposed)], slug(Fixture.onDisk(repoPath)), "\(serviceID): one destination for both forms")
        }
    }

    // MARK: - Slugs

    func testClaudeAndCodexNameAProjectTheirOwnWay() {
        // On this Mac all 48 Claude project folders are their cwd with every character but
        // an ASCII letter or digit turned into "-".
        XCTAssertEqual(ProjectWorktrees.claudeSlug("/Users/tester/Desktop/Usage tracker"), "-Users-tester-Desktop-Usage-tracker")
        XCTAssertEqual(
            ProjectWorktrees.claudeSlug("/Users/tester/Desktop/MS App/worktrees/doses"),
            "-Users-tester-Desktop-MS-App-worktrees-doses"
        )
        XCTAssertEqual(ProjectWorktrees.claudeSlug("/Users/tester/code/a.b_c"), "-Users-tester-code-a-b-c")
        XCTAssertEqual(
            ProjectWorktrees.codexSlug("/Users/tester/Desktop/Usage tracker"), "%2FUsers%2Ftester%2FDesktop%2FUsage%20tracker"
        )
    }

    func testCodexsSlugIsTheOneItsCostLogKeysAChatsProjectBy() async throws {
        let tree = try CodexTree(under: root)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let cwd = "/tmp/Codex Fixtures/alpha app"
        let thread = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: thread, threadID: thread, cwd: cwd,
                                     originator: "codex-tui", at: now.addingTimeInterval(-600)),
            CodexRollout.turnContext(turnID: "turn-p", model: "gpt-5.6-terra", effort: "high", cwd: cwd,
                                     at: now.addingTimeInterval(-590)),
            CodexRollout.record(at: now.addingTimeInterval(-300), threadID: thread, sessionID: thread, turnID: "turn-p",
                                responseID: "resp_p1", input: 1_000, cached: 400, output: 100, reasoning: 0),
        ], named: "rollout-2026-09-06T10-00-00-\(thread).jsonl")
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: now.addingTimeInterval(-3_600), to: now)
        XCTAssertEqual(log.turns.first?.projectSlug, ProjectWorktrees.codexSlug(cwd))
    }

    // MARK: - The fold

    func testAWorktreesChatsCountUnderItsRepository() {
        let wt = ProjectWorktrees.claudeSlug("/Users/tester/Desktop/usage-tracker-wt-tab")
        let main = ProjectWorktrees.claudeSlug("/Users/tester/Desktop/Usage tracker")
        let movie = "-Users-tester-Projects-movie"
        let end = Date(timeIntervalSince1970: 1_788_696_000)
        let window = LimitWindow(start: end.addingTimeInterval(-5 * 86_400), end: end)
        let share = Fixture.limitShare(window: window, chats: [
            Fixture.chatShare(id: "chat-c", project: movie, points: 4, cost: 240, lastAt: end),
            Fixture.chatShare(id: "chat-a", project: wt, points: 3, cost: 180, lastAt: end),
            Fixture.chatShare(id: "chat-b", project: main, points: 2, cost: 120, lastAt: end),
        ])
        let folds = ProjectWorktrees.folds([
            WorktreeLink(path: "/Users/tester/Desktop/usage-tracker-wt-tab", main: "/Users/tester/Desktop/Usage tracker", seenAt: end),
        ], serviceID: "claude")
        XCTAssertEqual(folds, [wt: main])

        let folded = LimitShareRules.foldingProjects(share, into: folds)
        XCTAssertEqual(folded.chats.map(\.id), ["chat-c", "chat-a", "chat-b"], "the chats keep their order")
        XCTAssertEqual(folded.chats.map(\.projectSlug), [movie, main, main], "so Chats names the repository too")
        XCTAssertEqual(folded.projects.map(\.id), [main, movie])
        XCTAssertEqual(folded.projects.first?.points ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(folded.projects.first?.chats, 2)
        XCTAssertEqual(folded.percent, share.percent, accuracy: 1e-9)
        XCTAssertEqual(LimitShareRules.foldingProjects(share, into: [:]), share, "no link, no change")
    }

    func testDirectoriesThatShareASlugFoldOnlyWhenTheyShareARepository() {
        // "a b" and "a-b" are one Claude project folder, two for Codex.
        let seen = Date(timeIntervalSince1970: 1_788_696_000)
        let apart = [
            WorktreeLink(path: "/Users/tester/a b", main: "/Users/tester/old", seenAt: seen),
            WorktreeLink(path: "/Users/tester/a-b", main: "/Users/tester/new", seenAt: seen.addingTimeInterval(60)),
        ]
        XCTAssertEqual(
            ProjectWorktrees.folds(apart, serviceID: "claude"), [:],
            "a chat in that folder could be either repository's: it folds nowhere"
        )
        XCTAssertEqual(ProjectWorktrees.folds(apart, serviceID: "codex"), [
            "%2FUsers%2Ftester%2Fa%20b": "%2FUsers%2Ftester%2Fold",
            "%2FUsers%2Ftester%2Fa%2Db": "%2FUsers%2Ftester%2Fnew",
        ])
        let together = [
            WorktreeLink(path: "/Users/tester/a b", main: "/Users/tester/repo", seenAt: seen),
            WorktreeLink(path: "/Users/tester/a-b", main: "/Users/tester/repo", seenAt: seen.addingTimeInterval(60)),
        ]
        XCTAssertEqual(
            ProjectWorktrees.folds(together, serviceID: "claude"), ["-Users-tester-a-b": "-Users-tester-repo"],
            "both are the same repository's"
        )
        XCTAssertEqual(ProjectWorktrees.folds(apart, serviceID: "grok"), [:], "the Limits tab measures no Grok chat")
    }
}

/// The layout `git worktree add` leaves (spec 2026-10-16 limit analytics § The tab, item 3),
/// built under a temporary directory.
extension Fixture {
    /// `parent/<name>`: a repository's main working tree, its `.git` a directory. An
    /// existing folder of that name is kept as it is.
    static func gitRepository(named name: String, in parent: URL) throws -> URL {
        let repository = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git/worktrees", isDirectory: true), withIntermediateDirectories: true
        )
        return repository
    }

    /// `parent/<name>`, with a `Sources` folder: a linked worktree of `repository`, known as
    /// `id` in its `.git/worktrees`. Its `.git` file names that git directory absolutely, or
    /// relatively as `git worktree add --relative-paths` writes it (both under `parent`).
    static func gitWorktree(
        named name: String, id: String, of repository: URL, in parent: URL, relative: Bool = false
    ) throws -> URL {
        let worktree = parent.appendingPathComponent(name, isDirectory: true)
        let gitDir = repository.appendingPathComponent(".git/worktrees/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true
        )
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let named = relative ? "../\(repository.lastPathComponent)/.git/worktrees/\(id)" : gitDir.path
        try "gitdir: \(named)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return worktree
    }

    /// `parent/<name>` made with `mkdir(2)`, its name stored exactly as typed. A `URL` would
    /// store a non-ASCII name decomposed. Returns the path as typed.
    static func directoryAsTyped(_ name: String, in parent: URL) throws -> String {
        let path = parent.path + "/" + name
        guard mkdir(path, 0o755) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return path
    }

    /// `path` as the file system has it (`realpath(3)`): links followed, each name in its
    /// stored form, as `getcwd` gives it to the CLIs. `path` itself when it does not exist.
    static func onDisk(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
