import XCTest
@testable import Omelette

/// A worktree whose git directory is named through a symbolic link: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 3 (a chat run
/// in a worktree counts under the repository the worktree belongs to). The `gitdir:` path
/// is followed on disk before its `commondir` (`../..`) is read from it: `..` worked out
/// on the string would climb the link's own parents instead of the repository's. The
/// layouts are built in a temporary directory per test; the lookup answers as the file
/// system has the path (`realpath(3)`: the temp folder's `/var` is `/private/var`).
final class ProjectWorktreesSymlinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectWorktreesSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `root/<name>` with `.git/worktrees/feature/commondir` reading `../..`, as `git
    /// worktree add` leaves it.
    private func repository(_ name: String) throws -> String {
        let repo = root.path + "/" + name
        try mkdir(repo + "/.git/worktrees/feature")
        try write("../..\n", to: repo + "/.git/worktrees/feature/commondir")
        return repo
    }

    /// A worktree at `path` whose `.git` file names `gitDir`.
    private func worktree(at path: String, gitDir: String) throws -> String {
        try mkdir(path + "/Sources")
        try write("gitdir: \(gitDir)\n", to: path + "/.git")
        return path
    }

    func testAGitdirThroughALinkToTheWorktreesFolderLeadsToItsRepository() throws {
        let repo = try repository("Usage tracker")
        let link = root.path + "/worktrees-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: repo + "/.git/worktrees")
        let wt = try worktree(at: root.path + "/usage-tracker-wt-feature", gitDir: link + "/feature")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
        XCTAssertEqual(ProjectWorktrees.lookup(wt + "/Sources"), .linked(main: Fixture.onDisk(repo) + "/Sources"))
    }

    /// Walked on the string, `<other>/.git/wt/feature/../..` is `<other>/.git`: another
    /// repository's, which the chats would have been folded onto.
    func testALinkInsideAnotherRepositorysGitFolderDoesNotFoldOntoThatRepository() throws {
        let repo = try repository("main")
        let other = root.path + "/other"
        try mkdir(other + "/.git")
        try FileManager.default.createSymbolicLink(
            atPath: other + "/.git/wt", withDestinationPath: repo + "/.git/worktrees"
        )
        let wt = try worktree(at: root.path + "/wt", gitDir: other + "/.git/wt/feature")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    /// A relative `gitdir:` through the link is read from the worktree, then followed.
    func testARelativeGitdirThroughALinkIsFollowedToo() throws {
        let repo = try repository("main")
        try FileManager.default.createSymbolicLink(
            atPath: root.path + "/worktrees-link", withDestinationPath: repo + "/.git/worktrees"
        )
        let wt = try worktree(at: root.path + "/wt", gitDir: "../worktrees-link/feature")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    /// The common directory must still be a `.git` once followed: a bare repository's is
    /// not, whatever the path that leads to it.
    func testACommonDirectoryThatIsNotAGitFolderOnDiskIsNotLinked() throws {
        let bare = root.path + "/repo.git"
        try mkdir(bare + "/worktrees/feature")
        try write("../..\n", to: bare + "/worktrees/feature/commondir")
        // Named through a link called `.git`, the string would end in "/.git".
        try mkdir(root.path + "/alias")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/alias/.git", withDestinationPath: bare)
        let wt = try worktree(at: root.path + "/wt", gitDir: root.path + "/alias/.git/worktrees/feature")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .unlinked)
    }
}
