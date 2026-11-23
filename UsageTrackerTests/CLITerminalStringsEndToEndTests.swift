import XCTest
@testable import Omelette

/// The built tool itself, spawned as `OmeletteCLIEndToEndTests` spawns it, on a file whose
/// strings are hostile: what reaches its stdout from `status`, `status --json`,
/// `statusline` and `mcp`. The rule and its seam are pinned in-process
/// (`TerminalStringTests`, `StatusFileTerminalStringsTests`); this is the proof that the
/// commands read through that seam and print nothing past it.
/// Spec: docs/superpowers/specs/2026-11-23-terminal-strings.md § Design 1, 3 and 5.
final class CLITerminalStringsEndToEndTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!
    private var dropURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLITerminalStringsEndToEndTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appendingPathComponent("status.json")
        dropURL = directory.appendingPathComponent("statusline", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledCLIURL.path),
            "omelette missing at \(AgentPaths.bundledCLIURL.path)"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Run {
        let status: Int32
        let stdout: String
        let stdoutBytes: Data
        let stderr: String
    }

    private func publish(_ snapshot: StatusSnapshot) throws {
        try TerminalStringFixture.fileBytes(snapshot).write(to: statusURL, options: [.atomic])
    }

    /// The tool, pointed at this test's own status file and reading drop, never the
    /// developer's.
    private func runCLI(_ arguments: [String], stdin input: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = AgentPaths.bundledCLIURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[StatusFile.environmentKey] = statusURL.path
        environment[StatusLineDrop.environmentKey] = dropURL.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        // The requests are a few hundred bytes, far less than a pipe holds, so they are
        // written whole before the first answer is read.
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stdoutBytes: outData,
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Every command on the file at `statusURL`, each output with the shape it must keep.
    /// The MCP server answers `initialize`, `tools/list` and every request of
    /// `TerminalStringFixture.requests` in one run.
    private func everyOutput() throws -> [TerminalStringFixture.Output] {
        let loaded = try XCTUnwrap(StatusFile.load(from: statusURL))
        var outputs: [TerminalStringFixture.Output] = []

        let status = try runCLI(["status"])
        XCTAssertEqual(status.status, 0, status.stderr)
        XCTAssertTrue(String(data: status.stdoutBytes, encoding: .utf8) != nil, "status prints UTF-8")
        outputs.append(.init(name: "status", text: status.stdout, shape: .lines(TerminalStringFixture.statusLines(loaded))))

        let json = try runCLI(["status", "--json"])
        XCTAssertEqual(json.status, 0, json.stderr)
        XCTAssertTrue(String(data: json.stdoutBytes, encoding: .utf8) != nil, "status --json prints UTF-8")
        outputs.append(.init(name: "status --json", text: json.stdout, shape: .json))

        // The ids as the file spells them, hostile scalars and all, and the default.
        let written = try StatusFile.decoder.decode(StatusSnapshot.self, from: Data(contentsOf: statusURL))
        for provider in [nil] + written.services.map({ Optional($0.id) }) {
            let arguments = ["statusline"] + (provider.map { ["--provider", $0] } ?? [])
            let line = try runCLI(arguments)
            XCTAssertEqual(line.status, 0, line.stderr)
            outputs.append(.init(name: arguments.joined(separator: " ").debugDescription, text: line.stdout, shape: .lines(1)))
        }

        let requests = TerminalStringFixture.requests(for: written)
        let lines = [
            #"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#,
        ] + requests.map(\.line)
        let mcp = try runCLI(["mcp"], stdin: lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(mcp.status, 0, mcp.stderr)
        XCTAssertTrue(mcp.stdout.hasSuffix("\n"))
        let responses = mcp.stdout.dropLast().components(separatedBy: "\n")
        XCTAssertEqual(responses.count, lines.count, "one line out for each line in: no string added one")
        guard responses.count == lines.count else { return outputs }
        outputs.append(.init(name: "mcp initialize", text: responses[0], shape: .rpc(textLines: nil)))
        outputs.append(.init(name: "mcp tools/list", text: responses[1], shape: .rpc(textLines: nil)))
        for (request, response) in zip(requests, responses.dropFirst(2)) {
            outputs.append(.init(
                name: request.name, text: response,
                shape: .rpc(textLines: TerminalStringFixture.textLines(tool: request.tool, arguments: request.arguments, snapshot: loaded))
            ))
        }
        return outputs
    }

    // MARK: - Hostile strings

    /// Every string of the file hostile, every command and every tool: nothing the rule
    /// removes reaches stdout, raw or as a JSON escape, and no output gains a line.
    func testNoCommandPrintsARemovedScalarWhenEveryStringIsHostile() throws {
        try publish(TerminalStringFixture.everyString(at: Date()))

        let outputs = try everyOutput()

        // status, status --json, four status lines, initialize, tools/list, eight requests.
        XCTAssertEqual(outputs.count, 2 + 4 + 2 + 8)
        for output in outputs {
            TerminalStringFixture.assertNothingRemovedIsPrinted(output)
        }
    }

    /// The same commands on the same file did print them before the read was cleaned: the
    /// file on disk still holds every one, so it is the tool that leaves them out.
    func testTheFileItselfStillHoldsWhatTheToolLeavesOut() throws {
        try publish(TerminalStringFixture.everyString(at: Date()))

        let onDisk = try XCTUnwrap(String(data: Data(contentsOf: statusURL), encoding: .utf8))
        let object = try JSONSerialization.jsonObject(with: Data(onDisk.utf8))
        let held = Set(TerminalStringFixture.jsonStrings(object).flatMap { TerminalStringFixture.removed(in: $0) })
        XCTAssertEqual(held, ["U+001B", "U+009B", "U+202E", "U+200B", "U+000A"])

        let json = try runCLI(["status", "--json"])

        XCTAssertEqual(json.status, 0)
        XCTAssertNotEqual(json.stdout, onDisk)
        let printed = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8))
        XCTAssertEqual(Set(TerminalStringFixture.jsonStrings(printed).flatMap { TerminalStringFixture.removed(in: $0) }), [])
    }

    /// What a person sees: the agent's project and activity in `status --json` and in the
    /// MCP paragraph, the provider's name in `status`, an escape sequence and a line break
    /// in each.
    func testAnEscapeSequenceInAProjectIsPrintedAsPlainTextOnOneLine() throws {
        let hostile = "fix\u{1B}]52;c;aGVsbG8=\u{07}\r\nbug\u{202E}"
        try publish(StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: Date(),
            services: [StatusSnapshot.Service(
                id: "claude", name: hostile, state: "ok", retained: false, retainedAt: nil, plan: hostile,
                windows: [StatusSnapshot.Window(id: "five_hour", label: hostile, percent: 42, kind: "session")]
            )],
            agents: StatusSnapshot.Agents(
                needsYou: 0, working: 1,
                sessions: [StatusSnapshot.Session(id: hostile, project: hostile, state: "working", activity: hostile)]
            )
        ))
        let shown = "fix]52;c;aGVsbG8= bug"

        let status = try runCLI(["status"])
        let mcp = try runCLI(["mcp"], stdin: TerminalStringFixture.request(1, tool: "get_agents") + "\n")
        let json = try runCLI(["status", "--json"])

        XCTAssertEqual(status.stdout, "\(shown)  \(shown) 42%\nAgents: 1 working\n")
        XCTAssertTrue(mcp.stdout.contains("\(shown) — working: \(shown). Numbers as of "), mcp.stdout)
        XCTAssertTrue(mcp.stdout.contains(#""sessions":[{"activity":"\#(shown)","id":"\#(shown)","project":"\#(shown)","state":"working"}]"#), mcp.stdout)
        XCTAssertTrue(json.stdout.contains(#""activity" : "\#(shown)""#), json.stdout)
        XCTAssertTrue(json.stdout.contains(#""plan" : "\#(shown)""#), json.stdout)
    }

    // MARK: - Nothing to clean

    /// A file with nothing to clean: `status --json` is the file's own bytes and the
    /// structured half of every tool is what the same request answers from the value the
    /// app wrote. (The paragraphs carry the clock and the machine's locale; they are
    /// pinned byte for byte in `StatusFileTerminalStringsTests`.)
    func testACleanFileIsPrintedAsBefore() throws {
        let written = TerminalStringFixture.cleanSnapshot(at: Date())
        try publish(written)

        let json = try runCLI(["status", "--json"])
        XCTAssertEqual(json.stdoutBytes, try Data(contentsOf: statusURL))

        let status = try runCLI(["status"])
        XCTAssertEqual(status.status, 0)
        XCTAssertEqual(status.stdout.components(separatedBy: "\n").count - 1, 4)
        XCTAssertTrue(status.stdout.hasPrefix("Claude  Session 42%, resets in "), status.stdout)
        XCTAssertTrue(status.stdout.hasSuffix("Grok    Sign in needed\nAgents: 1 needs you, 1 working\n"), status.stdout)

        let requests = TerminalStringFixture.requests(for: written)
        let mcp = try runCLI(["mcp"], stdin: requests.map(\.line).joined(separator: "\n") + "\n")
        let responses = mcp.stdout.dropLast().components(separatedBy: "\n")
        XCTAssertEqual(responses.count, requests.count)
        for (request, response) in zip(requests, responses) {
            let expected = try XCTUnwrap(MCPServer.handle(request.line, snapshot: written, now: Date()))
            XCTAssertEqual(try serialisedBlock(response), try serialisedBlock(expected), request.name)
        }
    }

    /// The second content block of a tool's answer: its structured data as text.
    private func serialisedBlock(_ response: String) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.last?["text"] as? String)
    }

    // MARK: - A file the cleaning refuses

    /// A byte-order mark in front of the file: Foundation would decode it and `status
    /// --json` would print the mark. The tool answers as it does for any file it cannot
    /// read, and prints nothing.
    func testAFileWithAByteOrderMarkIsNotRunningAndNothingIsPrinted() throws {
        let data = try TerminalStringFixture.fileBytes(TerminalStringFixture.cleanSnapshot(at: Date()))
        try (Data([0xEF, 0xBB, 0xBF]) + data).write(to: statusURL)

        for arguments in [["status"], ["status", "--json"]] {
            let run = try runCLI(arguments)
            XCTAssertEqual(run.status, CLIText.noDataExitCode, arguments.joined(separator: " "))
            XCTAssertTrue(run.stdoutBytes.isEmpty, arguments.joined(separator: " "))
            XCTAssertEqual(run.stderr, CLIText.notRunning + "\n")
        }
        XCTAssertEqual(try runCLI(["statusline"]).stdout, "\n")
    }
}
