import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1: Claude's switch
/// defaults to on when `~/.claude` exists, Claude.app is in /Applications or
/// ~/Applications, or `last-known.json` holds a Claude reading — the last one covers
/// Claude Code kept under `CLAUDE_CONFIG_DIR` with no `~/.claude`. The machine is passed
/// in: the paths answer from a closure, the stored file is a temp file.
final class ClaudeInstalledRuleTests: XCTestCase {
    private var directory: URL!
    /// Not a real home: the rule only joins paths onto it.
    private let home = "/test-home"
    private let readAt = Date(timeIntervalSince1970: 1_793_100_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeInstalledRuleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testClaudeCodesFolderInTheHomeIsEnough() {
        var fileReads = 0
        let on = ClaudeOAuthProvider.isClaudeInstalled(
            home: home,
            fileExists: { $0 == "/test-home/.claude" },
            lastKnownServiceIDs: { fileReads += 1; return [] }
        )
        XCTAssertTrue(on)
        XCTAssertEqual(fileReads, 0, "a path that answered spares the file read")
    }

    func testTheClaudeAppInApplicationsIsEnough() {
        XCTAssertTrue(ClaudeOAuthProvider.isClaudeInstalled(
            home: home, fileExists: { $0 == "/Applications/Claude.app" }, lastKnownServiceIDs: { [] }
        ))
    }

    func testTheClaudeAppInTheHomeApplicationsFolderIsEnough() {
        XCTAssertTrue(ClaudeOAuthProvider.isClaudeInstalled(
            home: home, fileExists: { $0 == "/test-home/Applications/Claude.app" }, lastKnownServiceIDs: { [] }
        ))
    }

    func testAKeptClaudeReadingIsEnoughWithNoFolderAndNoApp() {
        XCTAssertTrue(ClaudeOAuthProvider.isClaudeInstalled(
            home: home, fileExists: { _ in false }, lastKnownServiceIDs: { ["codex", "claude"] }
        ))
    }

    func testNoSignOfClaudeLeavesTheSwitchOff() {
        XCTAssertFalse(ClaudeOAuthProvider.isClaudeInstalled(
            home: home, fileExists: { _ in false }, lastKnownServiceIDs: { ["codex", "grok"] }
        ))
    }

    func testTheStoredFileNamesEveryProviderItKeptAReadingFor() async throws {
        let file = directory.appendingPathComponent("last-known.json")
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 12, kind: .session)],
            at: readAt
        )
        let codex = Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(id: "codex_session", label: "Session", percent: 30, kind: .session)],
            at: readAt
        )
        await LastKnownStore(fileURL: file).remember([claude, codex])

        XCTAssertEqual(LastKnownStore.storedServiceIDs(fileURL: file), ["claude", "codex"])
        XCTAssertTrue(
            ClaudeOAuthProvider.isClaudeInstalled(
                home: home, fileExists: { _ in false },
                lastKnownServiceIDs: { LastKnownStore.storedServiceIDs(fileURL: file) }
            ),
            "Claude Code under CLAUDE_CONFIG_DIR: no ~/.claude, but Omelette kept its reading"
        )
    }

    func testAMissingOrUnreadableFileKeepsNoReading() throws {
        XCTAssertEqual(LastKnownStore.storedServiceIDs(fileURL: directory.appendingPathComponent("absent.json")), [])
        let garbage = directory.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        XCTAssertEqual(LastKnownStore.storedServiceIDs(fileURL: garbage), [])
    }
}
