import XCTest
@testable import Omelette

/// The rename (plan 2026-10-31-brioche-rename, R3): the command's link may find a file that is
/// not ours at its path, since another tool ships a `brioche` too. Only what we made is ours
/// to replace.
final class CLILinkForeignFileTests: XCTestCase {
    private var root: URL!
    private var target: URL!
    private var link: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLILinkForeignFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        target = root.appendingPathComponent("Brioche.app/Contents/Helpers/omelette")
        link = root.appendingPathComponent("bin/brioche")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func destination() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    func testAPathWithNothingOnItIsNotForeignAndGetsTheLink() throws {
        XCTAssertFalse(AgentPaths.cliLinkIsForeign(link, target: target))

        XCTAssertTrue(try AgentPaths.refreshCLISymlink(link: link, target: target))

        XCTAssertEqual(try destination(), target.path)
        XCTAssertFalse(AgentPaths.cliLinkIsForeign(link, target: target), "what we just made is ours")
    }

    func testARegularFileIsLeftExactlyAsItWas() throws {
        let theirs = Data("#!/bin/sh\necho another tool\n".utf8)
        try theirs.write(to: link)

        XCTAssertTrue(AgentPaths.cliLinkIsForeign(link, target: target))
        XCTAssertFalse(try AgentPaths.refreshCLISymlink(link: link, target: target))

        XCTAssertEqual(try Data(contentsOf: link), theirs)
    }

    func testADirectoryIsLeftWithWhatIsInIt() throws {
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let inside = link.appendingPathComponent("kept")
        try Data("kept".utf8).write(to: inside)

        XCTAssertFalse(try AgentPaths.refreshCLISymlink(link: link, target: target))

        XCTAssertEqual(try Data(contentsOf: inside), Data("kept".utf8))
    }

    func testALinkToAnotherToolIsLeftEvenWhenItDangles() throws {
        let elsewhere = "/opt/brioche/bin/brioche"
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: elsewhere)

        XCTAssertFalse(try AgentPaths.refreshCLISymlink(link: link, target: target))

        XCTAssertEqual(try destination(), elsewhere)
    }

    func testALinkToAnEarlierCopyOfTheAppIsRepointed() throws {
        let earlier = root.appendingPathComponent("Omelette.app/Contents/Helpers/omelette")
        try FileManager.default.createDirectory(at: earlier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: earlier)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: earlier.path)

        XCTAssertFalse(AgentPaths.cliLinkIsForeign(link, target: target))
        XCTAssertTrue(try AgentPaths.refreshCLISymlink(link: link, target: target))

        XCTAssertEqual(try destination(), target.path)
    }

    func testADanglingLinkToADeletedCopyOfTheAppIsRepointed() throws {
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/Applications/Gone.app/Contents/Helpers/omelette"
        )

        XCTAssertTrue(try AgentPaths.refreshCLISymlink(link: link, target: target))

        XCTAssertEqual(try destination(), target.path)
    }
}
