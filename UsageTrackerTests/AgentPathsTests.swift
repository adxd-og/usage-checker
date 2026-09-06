import XCTest
@testable import Omelette

final class AgentPathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPathsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTarget(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    func testConstantsMatchTheContract() {
        XCTAssertEqual(AgentPaths.helperVersion, 2)
        XCTAssertEqual(AgentPaths.wireVersion, 2)
        XCTAssertEqual(AgentPaths.supportedWireVersions, 1...2)
        XCTAssertEqual(AgentPaths.decisionTimeoutEnvironmentKey, "OMELETTE_DECISION_TIMEOUT")
        XCTAssertEqual(AgentPaths.requestIDLength, 32)
        XCTAssertEqual(AgentPaths.helperName, "omelette-hook")
        XCTAssertEqual(AgentPaths.socketURL.lastPathComponent, "agent.sock")
        XCTAssertEqual(AgentPaths.socketURL.deletingLastPathComponent().lastPathComponent, "UsageTracker")
        XCTAssertEqual(AgentPaths.helperSymlinkURL.pathComponents.suffix(3), ["UsageTracker", "bin", "omelette-hook"])
        XCTAssertEqual(AgentPaths.bundledHelperURL.pathComponents.suffix(3), ["Contents", "Helpers", "omelette-hook"])
        XCTAssertEqual(AgentPaths.historyURL.lastPathComponent, "agent-sessions.jsonl")
        XCTAssertEqual(AgentPaths.claudeSettingsURL.pathComponents.suffix(2), [".claude", "settings.json"])
        XCTAssertEqual(AgentPaths.claudeProjectsURL.pathComponents.suffix(2), [".claude", "projects"])
        XCTAssertEqual(AgentPaths.codexConfigURL.pathComponents.suffix(2), [".codex", "config.toml"])
        XCTAssertEqual(AgentPaths.codexHooksURL.pathComponents.suffix(2), [".codex", "hooks.json"])
        XCTAssertEqual(AgentPaths.codexSessionsURL.pathComponents.suffix(2), [".codex", "sessions"])
        XCTAssertEqual(AgentPaths.cliName, "omelette")
        XCTAssertEqual(AgentPaths.cliSymlinkURL.pathComponents.suffix(3), ["UsageTracker", "bin", "omelette"])
        XCTAssertEqual(AgentPaths.bundledCLIURL.pathComponents.suffix(3), ["Contents", "Helpers", "omelette"])
        XCTAssertEqual(AgentPaths.statusFileURL.pathComponents.suffix(2), ["UsageTracker", "status.json"])
        XCTAssertEqual(AgentPaths.binURL.pathComponents.suffix(2), ["UsageTracker", "bin"])
    }

    func testSocketPathFitsInSockaddrUn() {
        // sun_path is 104 bytes including the NUL; a longer path cannot be bound at all.
        XCTAssertLessThanOrEqual(AgentPaths.socketURL.path.utf8.count, AgentPaths.maxSocketPathBytes,
                                 "home directory too long for a Unix socket at \(AgentPaths.socketURL.path)")
    }

    func testRefreshCreatesTheLinkAndItsDirectory() throws {
        let target = try makeTarget("omelette-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")

        let changed = try AgentPaths.refreshHelperSymlink(link: link, target: target)

        XCTAssertTrue(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testRefreshIsIdempotent() throws {
        let target = try makeTarget("omelette-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")
        _ = try AgentPaths.refreshHelperSymlink(link: link, target: target)

        let changed = try AgentPaths.refreshHelperSymlink(link: link, target: target)

        XCTAssertFalse(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testRefreshRepointsALinkToAnOldCopy() throws {
        let old = try makeTarget("old-hook")
        let new = try makeTarget("new-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")
        _ = try AgentPaths.refreshHelperSymlink(link: link, target: old)

        let changed = try AgentPaths.refreshHelperSymlink(link: link, target: new)

        XCTAssertTrue(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), new.path)
    }

    func testRefreshReplacesADanglingLinkAndARegularFile() throws {
        let target = try makeTarget("omelette-hook")
        let link = root.appendingPathComponent("bin/omelette-hook")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Dangling: the app the link pointed at was deleted.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("gone").path)
        XCTAssertTrue(try AgentPaths.refreshHelperSymlink(link: link, target: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)

        // Regular file where the link should be (someone copied the binary by hand).
        try FileManager.default.removeItem(at: link)
        try Data("stale".utf8).write(to: link)
        XCTAssertTrue(try AgentPaths.refreshHelperSymlink(link: link, target: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    /// The app computes the file's path through Application Support and the CLI
    /// computes it from `$HOME` with no app around to ask. Two spellings of one path
    /// is exactly the bug that would make `omelette status` read an empty directory.
    func testTheAppAndTheCLIAgreeOnWhereStatusJSONIs() {
        XCTAssertEqual(AgentPaths.statusFileURL.path, StatusFile.defaultURL().path)
        XCTAssertEqual(
            AgentPaths.statusFileURL.path,
            AgentPaths.appSupportURL.appendingPathComponent("status.json").path
        )
    }

    func testTheCLILinkUsesTheSameRoutineAsTheHelperLink() throws {
        let target = try makeTarget("omelette")
        let link = root.appendingPathComponent("bin/omelette")

        XCTAssertTrue(try AgentPaths.refreshCLISymlink(link: link, target: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertFalse(try AgentPaths.refreshCLISymlink(link: link, target: target))
    }

    /// Both links live in the same directory and neither may disturb the other — an
    /// update that repointed `omelette` and left `omelette-hook` dangling would take
    /// every hook down with it.
    func testTheTwoLinksAreIndependent() throws {
        let hook = try makeTarget("omelette-hook")
        let cli = try makeTarget("omelette")
        let hookLink = root.appendingPathComponent("bin/omelette-hook")
        let cliLink = root.appendingPathComponent("bin/omelette")

        _ = try AgentPaths.refreshHelperSymlink(link: hookLink, target: hook)
        _ = try AgentPaths.refreshCLISymlink(link: cliLink, target: cli)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: hookLink.path), hook.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path), cli.path)
    }
}
