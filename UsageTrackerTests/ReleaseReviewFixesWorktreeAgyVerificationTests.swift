import XCTest
@testable import Omelette

/// The release-review fix round, the second half (spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab item 3 for worktrees;
/// `docs/superpowers/specs/2026-10-16-antigravity-argon.md` for the agy runs): worktree
/// layouts the implementer's tests do not build, and the agy registry under quit.
/// Layouts live in a temporary directory per test.
final class ReleaseReviewFixesWorktreeAgyVerificationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseReviewFixesWorktreeAgy-\(UUID().uuidString)", isDirectory: true)
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

    private func link(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    /// `root/<name>` with `.git/worktrees/feature/commondir` reading `common`.
    private func repository(_ name: String, common: String = "../..") throws -> String {
        let repo = root.path + "/" + name
        try mkdir(repo + "/.git/worktrees/feature")
        try write(common + "\n", to: repo + "/.git/worktrees/feature/commondir")
        return repo
    }

    private func worktree(at path: String, dotGit: String) throws -> String {
        try mkdir(path + "/Sources")
        try write(dotGit, to: path + "/.git")
        return path
    }

    // MARK: - Worktrees

    func testAnAbsoluteGitdirAndAnAbsoluteCommondirLeadToTheRepository() throws {
        let repo = try repository("main")
        try write(repo + "/.git\n", to: repo + "/.git/worktrees/feature/commondir")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(repo)/.git/worktrees/feature\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    func testARelativeGitdirWithoutAnyLinkLeadsToTheRepository() throws {
        let repo = try repository("main")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: ../main/.git/worktrees/feature\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    /// Walked on the string, `<link>/../..` is the link's own parents, not the repository.
    func testAGitdirThatIsALinkStraightToTheWorktreesEntryLeadsToTheRepository() throws {
        let repo = try repository("main")
        let entry = root.path + "/entry"
        try link(entry, to: repo + "/.git/worktrees/feature")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(entry)\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    func testAWorktreeReachedThroughALinkIsTheSameWorktree() throws {
        let repo = try repository("main")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(repo)/.git/worktrees/feature\n")
        try link(root.path + "/shortcut", to: wt)

        XCTAssertEqual(ProjectWorktrees.lookup(root.path + "/shortcut/Sources"), .linked(main: Fixture.onDisk(repo) + "/Sources"))
    }

    func testAGitdirNamedWithATrailingSlashLeadsToTheRepository() throws {
        let repo = try repository("main")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(repo)/.git/worktrees/feature/\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    func testAGitFileWithWindowsLineEndsLeadsToTheRepository() throws {
        let repo = try repository("main", common: "../..\r")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(repo)/.git/worktrees/feature\r\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    func testARepositoryWhoseNameHoldsASpaceAndANonAsciiLetterIsFollowed() throws {
        let repo = try repository("Usage tracker é")
        let link = root.path + "/lnk"
        try self.link(link, to: repo + "/.git/worktrees")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(link)/feature\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .linked(main: Fixture.onDisk(repo)))
    }

    func testAGitdirPointingAtAMissingFolderIsNotLinkedAndNeverMissing() throws {
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(root.path)/gone/.git/worktrees/feature\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .unlinked)
        XCTAssertEqual(ProjectWorktrees.lookup(wt + "/Sources"), .unlinked)
    }

    func testACommondirPointingAtAMissingFolderIsNotLinked() throws {
        let repo = try repository("main", common: "../../../nowhere/.git")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(repo)/.git/worktrees/feature\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .unlinked)
    }

    func testABrokenLinkInTheGitdirIsNotLinked() throws {
        try link(root.path + "/dangling", to: root.path + "/not-there")
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir: \(root.path)/dangling/feature\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .unlinked)
    }

    func testAGitdirLineWithNoPathIsNotLinked() throws {
        let wt = try worktree(at: root.path + "/wt", dotGit: "gitdir:\n")

        XCTAssertEqual(ProjectWorktrees.lookup(wt), .unlinked)
    }

    // MARK: - agy under quit

    private func sleeper() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    /// Runs asked for after the quit answer an error each and start nothing; they hand
    /// back every descriptor they took.
    func testManyRunsAfterTheQuitLeakNoDescriptor() async throws {
        let registry = ChildProcessRegistry()
        registry.terminateAll()
        let before = openDescriptors()

        for _ in 0..<300 {
            do {
                _ = try await AgyCommand.run(
                    executable: "/usr/bin/true", arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                    directory: root, deadline: 5, killGrace: 0.2, registry: registry
                )
                XCTFail("no run after the quit")
            } catch {
                XCTAssertNotNil(error as? AgyUsageError)
            }
        }

        // The pipe's descriptors go back when Foundation releases the objects, a moment
        // after the answer (measured: 300 held at once, 0 two seconds later).
        let end = Date().addingTimeInterval(10)
        while openDescriptors() - before >= 10, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertLessThan(openDescriptors() - before, 10)
        XCTAssertEqual(registry.runningCount, 0)
    }

    /// A race the lock must settle: whichever side wins, no child is left running after
    /// both `terminateAll()` and every registration have come back.
    func testNoChildRegisteredAroundTheQuitIsLeftRunning() async throws {
        let registry = ChildProcessRegistry()
        let children = (0..<40).map { _ in sleeper() }
        defer { for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        await withTaskGroup(of: Void.self) { group in
            for child in children {
                group.addTask {
                    guard registry.register(child) else { return }
                    try? child.run()
                    registry.didStart(child)
                }
            }
            group.addTask { registry.terminateAll() }
        }

        let end = Date().addingTimeInterval(5)
        while children.contains(where: { $0.isRunning }), Date() < end {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(children.contains { $0.isRunning }, "every child that started was stopped by the quit")
    }

    func testTerminateAllTwiceKeepsTheRegistryClosedAndDoesNotCrash() {
        let registry = ChildProcessRegistry()
        registry.terminateAll()
        registry.terminateAll()

        XCTAssertFalse(registry.register(sleeper()))
    }

    func testAChildThatHasAlreadyExitedBeforeDidStartIsHarmless() async throws {
        let registry = ChildProcessRegistry()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertTrue(registry.register(child))
        try child.run()
        child.waitUntilExit()
        registry.terminateAll()

        registry.didStart(child)

        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationStatus, 0)
    }
}
