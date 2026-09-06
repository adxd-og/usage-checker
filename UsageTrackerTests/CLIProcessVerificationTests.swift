import XCTest
@testable import Omelette

/// Independent verification of the `omelette` binary as a process, derived from the
/// spec's command list and the plan's Tasks 5-7 and 12, not from
/// `OmeletteCLIEndToEndTests`. Covers: no-argument behaviour, a bad option to a known
/// command, a malformed status.json (not a crash), a from-the-future `version`, an
/// empty-services snapshot, wall-clock budget, a large stdin blob on `statusline`, an
/// unknown provider with nothing else to say, and a JSON-RPC batch array over `mcp`.
final class CLIProcessVerificationTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    /// 2026-09-06 11:20:00 UTC.
    let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProcessVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appendingPathComponent("status.json")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: AgentPaths.bundledCLIURL.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
        let elapsed: TimeInterval
    }

    func publish(_ snapshot: StatusSnapshot?) throws {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: statusURL)
            return
        }
        var data = try StatusFile.encoder.encode(snapshot)
        data.append(0x0A)
        try data.write(to: statusURL, options: [.atomic])
    }

    func writeRaw(_ bytes: Data) throws {
        try bytes.write(to: statusURL, options: [.atomic])
    }

    @discardableResult
    func runCLI(_ arguments: [String], stdin input: Data? = nil) throws -> Run {
        let process = Process()
        process.executableURL = AgentPaths.bundledCLIURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[StatusFile.environmentKey] = statusURL.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let started = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            elapsed: Date().timeIntervalSince(started)
        )
    }

    func sample(updatedAt: Date? = nil) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: updatedAt ?? Date(),
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: "Max 5x",
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: 42,
                            resetsAt: (updatedAt ?? Date()).addingTimeInterval(70 * 60), kind: "session"
                        ),
                    ],
                    todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(needsYou: 0, working: 0, sessions: [])
        )
    }

    // MARK: - No arguments

    /// `CLICommand.parse([])` returns `.help`, and `.help` exits 0 — this is a
    /// deliberately different answer from a usage error (64): the plan's own attack
    /// list flags this as ambiguous ("no args (usage, exit 64?)"), so pin the real,
    /// shipped behaviour with the actual binary.
    func testNoArgumentsPrintsUsageAndExitsZeroNotSixtyFour() throws {
        let run = try runCLI([])

        XCTAssertEqual(run.status, 0, "bare `omelette` is the same as --help, not a usage error")
        XCTAssertTrue(run.stdout.contains("omelette status"), run.stdout)
        XCTAssertTrue(run.stderr.isEmpty)
    }

    // MARK: - Bad option to a known command

    func testAnUnknownStatusOptionExits64() throws {
        let run = try runCLI(["status", "--bogus"])

        XCTAssertEqual(run.status, CLIText.usageExitCode)
        XCTAssertTrue(run.stderr.contains("Unknown option for `status`: --bogus"), run.stderr)
    }

    func testMCPTakesNoOptionsAndExits64WhenGivenOne() throws {
        let run = try runCLI(["mcp", "--verbose"])

        XCTAssertEqual(run.status, CLIText.usageExitCode)
        XCTAssertTrue(run.stderr.contains("mcp"), run.stderr)
    }

    // MARK: - A malformed status.json is exit 2, not a crash

    func testGarbageBytesOnDiskAreExit2NotACrash() throws {
        try writeRaw(Data("{ this is not json, at all, and has no closing brace".utf8))

        let run = try runCLI(["status"])

        XCTAssertEqual(run.status, CLIText.noDataExitCode)
        XCTAssertEqual(run.stderr, CLIText.notRunning + "\n")
        XCTAssertTrue(run.stdout.isEmpty)
    }

    /// `version: 2` — a file from a build ahead of this one. `StatusFile.load` refuses
    /// anything but `currentVersion`, so this must read exactly like "not running",
    /// never crash and never guess at unknown keys.
    func testAFutureVersionTwoFileIsTreatedAsNotRunning() throws {
        let text = """
        {"version":2,"updatedAt":"2026-09-06T11:20:00Z","services":[],"agents":{"needsYou":0,"working":0,"sessions":[]}}
        """
        try writeRaw(Data(text.utf8))

        let run = try runCLI(["status"])

        XCTAssertEqual(run.status, CLIText.noDataExitCode)
        XCTAssertEqual(run.stderr, CLIText.notRunning + "\n")
    }

    // MARK: - Empty services

    func testEmptyServicesAndNoAgentsPrintsTheEmptyLine() throws {
        let empty = StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: Date(),
            services: [], agents: .none
        )
        try publish(empty)

        let run = try runCLI(["status"])

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, StatusText.emptyLine + "\n")
    }

    // MARK: - Wall clock

    /// The plan's budget is "under 50 ms of work"; the end-to-end tests already assert
    /// under 1 s to absorb process spawn and ICU load. This is the tighter, still
    /// generous bound the attack list asks for.
    func testStatusRunsInUnderTwoHundredMilliseconds() throws {
        try publish(sample())

        let run = try runCLI(["status"])

        XCTAssertEqual(run.status, 0)
        XCTAssertLessThan(run.elapsed, 0.2, "spawn + a file read + a string join, nothing more")
    }

    // MARK: - statusline must drain a big blob and never hang

    /// Claude Code's real payload is a small JSON object, but nothing in the contract
    /// bounds it, and `drainStandardInput` must not block forever on a slow or large
    /// write. 8 MB comfortably exceeds any pipe buffer, forcing an interleaved
    /// read/write if the tool did not drain properly.
    func testStatusLineDrainsALargeStdinBlobWithoutHanging() throws {
        try publish(sample())
        let blob = Data(repeating: 0x41, count: 8 * 1024 * 1024)

        let run = try runCLI(["statusline"], stdin: blob)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.hasPrefix("◐ 42% · resets in "), run.stdout)
        XCTAssertTrue(run.stdout.hasSuffix("· $4.20 today\n"), run.stdout)
        XCTAssertEqual(run.stdout.filter { $0 == "\n" }.count, 1, "one line out, regardless of stdin size")
        XCTAssertLessThan(run.elapsed, 3, "a big write must not stall the tool")
    }

    // MARK: - Unknown provider, nothing else to say

    func testAnUnknownProviderWithNoFlagIsAnEmptyLineAndExitZero() throws {
        try publish(sample())

        let run = try runCLI(["statusline", "--provider", "gemini"])

        XCTAssertEqual(run.status, 0, "a status line must never report an error")
        XCTAssertEqual(run.stdout, "\n", "no gemini service in the file, and no agent waiting")
        XCTAssertTrue(run.stderr.isEmpty)
    }

    // MARK: - MCP: a JSON-RPC batch array

    /// JSON-RPC 2.0 allows a batch: an array of request objects on one line. Nothing
    /// in `MCPServer.handle` special-cases an array — `any as? [String: Any]` fails for
    /// one — so this pins the real, current answer: a single Invalid Request with a
    /// null id, not one response per batched call and not a hang.
    func testABatchOfRealRequestObjectsIsOneInvalidRequestNotPerItemResponses() throws {
        try publish(sample())
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"# + "\n"

        let run = try runCLI(["mcp"], stdin: Data(batch.utf8))

        XCTAssertEqual(run.status, 0)
        let lines = run.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, 1, "a batch is not fanned out into one response per request: \(run.stdout)")
        XCTAssertTrue(lines.first?.contains("-32600") == true, run.stdout)
        XCTAssertTrue(lines.first?.contains("\"id\":null") == true, run.stdout)
    }

    /// Closing stdin immediately (no input at all) must end the `mcp` loop promptly —
    /// `readLine` returns nil on EOF, and the loop must not spin or wait on anything else.
    func testMCPWithNoInputAtAllExitsWithinOneSecond() throws {
        try publish(sample())

        let run = try runCLI(["mcp"], stdin: Data())

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertLessThan(run.elapsed, 1, "closing stdin must end the process promptly")
    }
}
