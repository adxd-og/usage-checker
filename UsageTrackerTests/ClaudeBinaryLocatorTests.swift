import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, The binary: `claude` on
/// the login shell's PATH first; otherwise the newest copy the Claude desktop app bundles under
/// `~/Library/Application Support/Claude/claude-code/<version>/<hash>/claude.app/Contents/MacOS/claude`
/// — newest by version, then by modification date; no binary at all is nil. The PATH lookup
/// and the Application Support folder are passed in; the folder is a temp dir.
final class ClaudeBinaryLocatorTests: XCTestCase {
    private var root: URL!
    private var appSupport: URL { root.appendingPathComponent("Application Support", isDirectory: true) }
    private let earlier = Date(timeIntervalSince1970: 1_793_000_000)
    private let later = Date(timeIntervalSince1970: 1_793_100_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBinaryLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One bundled copy, the way the desktop app lays it out.
    @discardableResult
    private func bundled(version: String, hash: String, modified: Date, executable: Bool = true) throws -> String {
        let folder = appSupport.appendingPathComponent(
            "Claude/claude-code/\(version)/\(hash)/claude.app/Contents/MacOS", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644, .modificationDate: modified],
            ofItemAtPath: binary.path
        )
        return binary.path
    }

    func testClaudeOnTheLoginShellPATHComesFirst() throws {
        try bundled(version: "2.1.308", hash: "a93ded4b1b47", modified: later)
        XCTAssertEqual(
            ClaudeBinaryLocator.locate(onPATH: { "/opt/homebrew/bin/claude" }, applicationSupport: appSupport),
            "/opt/homebrew/bin/claude"
        )
    }

    func testWithoutOneOnThePATHTheNewestDesktopVersionIsUsed() throws {
        try bundled(version: "2.1.99", hash: "old", modified: later)
        let newest = try bundled(version: "2.1.308", hash: "a93ded4b1b47", modified: earlier)
        XCTAssertEqual(
            ClaudeBinaryLocator.locate(onPATH: { nil }, applicationSupport: appSupport), newest,
            "2.1.308 is newer than 2.1.99 whatever the dates say: versions compare as numbers"
        )
    }

    func testWithinOneVersionTheNewestCopyWins() throws {
        try bundled(version: "2.1.308", hash: "first", modified: earlier)
        let second = try bundled(version: "2.1.308", hash: "second", modified: later)
        XCTAssertEqual(ClaudeBinaryLocator.newestBundled(applicationSupport: appSupport), second)
    }

    func testAFolderWithoutAnExecutableIsSkipped() throws {
        let usable = try bundled(version: "2.1.300", hash: "usable", modified: earlier)
        try bundled(version: "2.1.400", hash: "broken", modified: later, executable: false)
        XCTAssertEqual(ClaudeBinaryLocator.newestBundled(applicationSupport: appSupport), usable)
    }

    func testNoClaudeAnywhereIsNoBinary() {
        XCTAssertNil(ClaudeBinaryLocator.locate(onPATH: { nil }, applicationSupport: appSupport))
    }

    func testTheBundledPathKeepsItsSpaces() throws {
        let path = try bundled(version: "2.1.308", hash: "a93ded4b1b47", modified: later)
        XCTAssertTrue(path.contains("Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude"))
        XCTAssertEqual(ClaudeBinaryLocator.locate(onPATH: { nil }, applicationSupport: appSupport), path)
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertEqual(ClaudeBinaryLocator.versionKey("2.1.308"), [2, 1, 308])
        XCTAssertTrue(ClaudeBinaryLocator.isNewer([2, 1, 308], than: [2, 1, 99]))
        XCTAssertFalse(ClaudeBinaryLocator.isNewer([2, 1], than: [2, 1, 0]), "a missing part is zero")
        XCTAssertFalse(ClaudeBinaryLocator.isNewer([2, 0, 9], than: [2, 1]))
    }
}
