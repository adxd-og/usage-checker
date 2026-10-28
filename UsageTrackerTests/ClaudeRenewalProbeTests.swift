import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, What the probe is allowed
/// to do: a renewal start runs in Omelette's own folder under one persisted session id, with
/// Claude Code's own flags and no prompt or command; a transcript it leaves under
/// `~/.claude/projects` is not permitted, so Omelette removes it after every start, success or
/// failure (CodexBarCore's cleaner is internal; this is its port), and before, for one a crash
/// left. Folders are temp dirs; the start is a closure.
final class ClaudeRenewalProbeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeRenewalProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var probe: URL { root.appendingPathComponent("UsageTracker/ClaudeRenewal", isDirectory: true) }
    private var claude: URL { root.appendingPathComponent(".claude", isDirectory: true) }
    private var project: URL {
        claude.appendingPathComponent("projects/\(ClaudeRenewalProbe.projectDirectoryName(for: probe))", isDirectory: true)
    }

    private func transcript(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: file)
        return file
    }

    // MARK: - Identity

    func testTheSessionIDIsMadeOnceAndKept() throws {
        XCTAssertNil(ClaudeRenewalProbe.storedSessionID(in: probe))
        let first = ClaudeRenewalProbe.sessionID(in: probe)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, first.lowercased())
        XCTAssertEqual(ClaudeRenewalProbe.sessionID(in: probe), first)
        XCTAssertEqual(ClaudeRenewalProbe.storedSessionID(in: probe), first)
        let file = probe.appendingPathComponent(ClaudeRenewalProbe.sessionIDFileName).path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int, 0o600)
    }

    func testAnUnreadableSessionFileIsReplaced() throws {
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try "not a uuid".write(to: probe.appendingPathComponent(ClaudeRenewalProbe.sessionIDFileName), atomically: true, encoding: .utf8)
        XCTAssertNil(ClaudeRenewalProbe.storedSessionID(in: probe))
        let made = ClaudeRenewalProbe.sessionID(in: probe)
        XCTAssertEqual(ClaudeRenewalProbe.storedSessionID(in: probe), made)
    }

    func testTheArgumentsAreClaudeCodesFlagsAndNoPrompt() {
        XCTAssertEqual(
            ClaudeRenewalProbe.arguments(sessionID: "5b0f3a52-8c1d-4e6f-9a7b-1c2d3e4f5a6b"),
            ["--allowed-tools", "", "--strict-mcp-config", "--session-id", "5b0f3a52-8c1d-4e6f-9a7b-1c2d3e4f5a6b"]
        )
    }

    func testTheProjectFolderNameFollowsClaudeCodesRule() {
        XCTAssertEqual(
            ClaudeRenewalProbe.projectDirectoryName(
                for: URL(fileURLWithPath: "/Users/tester/Library/Application Support/UsageTracker/ClaudeRenewal")
            ),
            "-Users-tester-Library-Application-Support-UsageTracker-ClaudeRenewal"
        )
    }

    func testALongFolderNameIsCutAndHashed() {
        let long = URL(fileURLWithPath: "/" + String(repeating: "a", count: 250))
        let name = ClaudeRenewalProbe.projectDirectoryName(for: long)
        XCTAssertTrue(name.hasPrefix("-" + String(repeating: "a", count: 199) + "-"), name)
        let hash = name.dropFirst(201)
        XCTAssertFalse(hash.isEmpty)
        XCTAssertTrue(hash.allSatisfy { $0.isNumber || ("a"..."z").contains($0) }, String(hash))
    }

    // MARK: - The cleaner

    func testTheCleanerRemovesTheStartsTranscriptsAndNothingElse() throws {
        let left = try transcript("5b0f3a52-8c1d-4e6f-9a7b-1c2d3e4f5a6b.jsonl", in: project)
        let notes = project.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: notes)
        let elsewhere = try transcript("other.jsonl", in: claude.appendingPathComponent("projects/-Users-tester-Projects-alpha"))

        let removed = ClaudeRenewalProbe.removeTranscripts(probeDirectory: probe, claudeRoot: claude)

        XCTAssertEqual(removed.map(\.lastPathComponent), [left.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "only transcripts go")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "another project is untouched")
    }

    func testAnEmptiedProjectFolderGoesToo() throws {
        _ = try transcript("a.jsonl", in: project)
        ClaudeRenewalProbe.removeTranscripts(probeDirectory: probe, claudeRoot: claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }

    // MARK: - One renewal

    private final class Start {
        var binary: String?
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var directory: URL?
        var leftoverGoneAtStart = false
    }

    func testARenewalCleansBeforeAndAfterTheStartAndPassesItsFlags() async throws {
        let leftover = try transcript("left-by-a-crash.jsonl", in: project)
        let start = Start()
        let project = self.project

        await ClaudeRenewalProbe.renew(
            binary: "/Applications/Claude Code/claude", directory: probe, claudeRoot: claude,
            environment: ["USER": "tester"]
        ) { binary, arguments, environment, directory in
            start.binary = binary
            start.arguments = arguments
            start.environment = environment
            start.directory = directory
            start.leftoverGoneAtStart = !FileManager.default.fileExists(atPath: leftover.path)
            // What a start that sent a message would leave.
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try? Data("{}\n".utf8).write(to: project.appendingPathComponent("written-by-the-start.jsonl"))
        }

        XCTAssertEqual(start.binary, "/Applications/Claude Code/claude")
        XCTAssertEqual(start.arguments, ClaudeRenewalProbe.arguments(sessionID: try XCTUnwrap(ClaudeRenewalProbe.storedSessionID(in: probe))))
        XCTAssertEqual(start.environment, ["USER": "tester"])
        XCTAssertEqual(start.directory, probe)
        XCTAssertTrue(start.leftoverGoneAtStart, "Claude Code refuses a session id whose transcript exists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path), "no transcript stays behind")
    }
}
