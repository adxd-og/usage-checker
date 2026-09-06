import XCTest
@testable import Omelette

/// Independent verification of `AgentPaths.refreshSymlink`, derived from the plan's
/// Task 4 doc comment ("A regular file, a dangling link or a link to an older copy of
/// the app is replaced"), not from `AgentPathsTests`. The attack list flags this
/// behaviour as worth pinning explicitly ("refuses to replace a regular file? (pin the
/// behaviour)"); this file pins it against a directory too, since `fileExists` and
/// `removeItem` treat a directory no differently from a plain file.
final class AgentPathsVerificationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPathsVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    /// The doc comment says "a regular file... is replaced (returns true)" but does
    /// not mention directories. `fileExists(atPath:)` is true for a directory and
    /// `removeItem` removes one recursively, so the code path is identical — confirm
    /// it really does replace (destructively) a directory sitting where the link
    /// should go, rather than throwing or silently leaving it in place.
    func testRefreshReplacesADirectoryAtTheLinkPathRatherThanRefusing() throws {
        let target = try makeTarget("omelette")
        let link = root.appendingPathComponent("bin/omelette")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: link.appendingPathComponent("leftover-file"))

        let changed = try AgentPaths.refreshSymlink(link: link, target: target)

        XCTAssertTrue(changed)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory)
        XCTAssertFalse(isDirectory.boolValue, "the directory must be gone, replaced by a symlink")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    /// The routine never checks whether `target` itself exists — it only compares the
    /// link's current destination string to `target.path`. Pointing at a target that
    /// has not been written yet must still succeed and produce a (dangling) symlink,
    /// since at app-launch time the embed step and the symlink refresh are two
    /// separate operations with no ordering guarantee enforced here.
    func testRefreshSucceedsEvenWhenTheTargetDoesNotExistYet() throws {
        let target = root.appendingPathComponent("not-written-yet")
        let link = root.appendingPathComponent("bin/omelette")

        let changed = try AgentPaths.refreshSymlink(link: link, target: target)

        XCTAssertTrue(changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path), "fileExists follows the link: it is dangling")
    }
}
