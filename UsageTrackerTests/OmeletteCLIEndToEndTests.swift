import XCTest
@testable import Omelette

/// Spawns the built `omelette`. The test host is `$(BUILT_PRODUCTS_DIR)/Omelette.app`,
/// so `AgentPaths.bundledCLIURL` is the binary the Embed Dependencies phase just copied
/// and signed — the same trick `OmeletteHookEndToEndTests` uses for the hook helper.
///
/// Every run points `OMELETTE_STATUS_FILE` at a temp file: the tool must never read the
/// developer's own status.json, and a test must never depend on whether Omelette
/// happens to be running.
final class OmeletteCLIEndToEndTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    /// 2026-09-06 11:20:00 UTC.
    let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmeletteCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        statusURL = directory.appendingPathComponent("status.json")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledCLIURL.path),
            "omelette missing at \(AgentPaths.bundledCLIURL.path) — check the OmeletteCLI target and the embed dependency in project.yml"
        )
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

    /// Writes `snapshot` to the temp status file, or removes it when nil.
    func publish(_ snapshot: StatusSnapshot?) throws {
        guard let snapshot else {
            try? FileManager.default.removeItem(at: statusURL)
            return
        }
        var data = try StatusFile.encoder.encode(snapshot)
        data.append(0x0A)
        try data.write(to: statusURL, options: [.atomic])
    }

    @discardableResult
    func runCLI(_ arguments: [String], stdin input: String? = nil) throws -> Run {
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
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        // Both pipes are drained before waiting: the tool writes far less than a pipe
        // buffer, but a `waitUntilExit` before a read is the classic way to deadlock.
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

    /// A snapshot with one healthy provider and one waiting agent. Tasks 6, 7 and 12
    /// all print from this.
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
            agents: StatusSnapshot.Agents(
                needsYou: 1, working: 2,
                sessions: [
                    StatusSnapshot.Session(
                        id: "claude:abc", project: "Usage tracker", state: "needsYou",
                        activity: "Remove build artifacts"
                    ),
                ]
            )
        )
    }

    // MARK: - The executable exists and answers

    func testVersionPrintsTheVersionAndExitsCleanly() throws {
        let run = try runCLI(["--version"])

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "omelette \(CLIText.version)\n")
        XCTAssertTrue(run.stderr.isEmpty)
        XCTAssertLessThan(run.elapsed, 1, "process spawn included; the work itself is a string")
    }

    func testHelpNamesEveryCommand() throws {
        let run = try runCLI(["--help"])

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.contains("omelette status"))
        XCTAssertTrue(run.stdout.contains("omelette statusline"))
        XCTAssertTrue(run.stdout.contains("omelette mcp"))
    }

    func testABadCommandExits64WithTheReasonOnStderr() throws {
        let run = try runCLI(["stats"])

        XCTAssertEqual(run.status, CLIText.usageExitCode)
        XCTAssertTrue(run.stdout.isEmpty, "a usage error is not output")
        XCTAssertTrue(run.stderr.contains("Unknown command: stats"), run.stderr)
        XCTAssertTrue(run.stderr.contains("omelette status"), "the usage text follows the reason")
    }

    /// The binary is Foundation-only by contract. `otool -L` is the assertion that
    /// keeps an accidental `import AppKit` — which would drag a whole UI framework into
    /// a tool that runs on every keystroke of a status line — from shipping.
    func testTheToolLinksNoUIFrameworks() throws {
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        otool.arguments = ["-L", AgentPaths.bundledCLIURL.path]
        let pipe = Pipe()
        otool.standardOutput = pipe
        try otool.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        otool.waitUntilExit()

        XCTAssertFalse(output.contains("AppKit.framework"), output)
        XCTAssertFalse(output.contains("SwiftUI.framework"), output)
        XCTAssertTrue(output.contains("Foundation.framework"), output)
    }
}
