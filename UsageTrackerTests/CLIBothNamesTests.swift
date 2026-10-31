import XCTest
@testable import Omelette

/// The rename (plan 2026-10-31-brioche-rename, R2, R4): one binary inside the bundle, two
/// links beside it, and a new setup that writes whichever name is ours.
final class CLIBothNamesTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private var target: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBothNamesTests-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        target = root.appendingPathComponent("Brioche.app/Contents/Helpers/omelette")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func destination(_ name: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent(name).path)
    }

    func testBothNamesPointAtTheOneBinary() throws {
        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target)

        XCTAssertEqual(try destination("brioche"), target.path)
        XCTAssertEqual(try destination("omelette"), target.path)
    }

    func testAForeignBriocheStaysAndOmeletteStillWorks() throws {
        let theirs = Data("another tool".utf8)
        try theirs.write(to: bin.appendingPathComponent("brioche"))

        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target)

        XCTAssertEqual(try Data(contentsOf: bin.appendingPathComponent("brioche")), theirs)
        XCTAssertEqual(try destination("omelette"), target.path)
    }

    func testANewSetupWritesBriocheWhenTheNameIsFreeOrOurs() throws {
        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target).lastPathComponent, "brioche")

        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: target)

        XCTAssertEqual(AgentPaths.usableCLILink(binDirectory: bin, target: target).lastPathComponent, "brioche")
    }

    /// Otherwise Enable would point a status line at somebody else's program.
    func testANewSetupWritesOmeletteWhenBriocheIsForeign() throws {
        try Data("another tool".utf8).write(to: bin.appendingPathComponent("brioche"))

        XCTAssertEqual(
            AgentPaths.usableCLILink(binDirectory: bin, target: target),
            bin.appendingPathComponent("omelette")
        )
    }

    /// Nothing to hand an installer: Enable stays off and Settings says why.
    func testWithBothNamesTakenNothingIsOffered() throws {
        XCTAssertFalse(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target))
        try Data("another tool".utf8).write(to: bin.appendingPathComponent("brioche"))
        XCTAssertFalse(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target))
        try Data("a third tool".utf8).write(to: bin.appendingPathComponent("omelette"))
        XCTAssertTrue(AgentPaths.bothCLINamesForeign(binDirectory: bin, target: target))

        XCTAssertEqual(
            IntegrationsSettingsCopy.commandNote(briocheIsForeign: true, omeletteIsForeign: true),
            SettingsCaption(
                text: "bin/brioche and bin/omelette belong to other tools, so Brioche left them alone. Move one of them to turn these on.",
                token: .warning
            )
        )
    }

    func testSettingsSaysSoOnlyWhenTheNameIsTaken() {
        XCTAssertNil(IntegrationsSettingsCopy.commandNote(briocheIsForeign: false))
        XCTAssertEqual(
            IntegrationsSettingsCopy.commandNote(briocheIsForeign: true),
            SettingsCaption(
                text: "bin/brioche belongs to another tool, so Brioche left it alone. Use `omelette` here: it is the same tool.",
                token: .warning
            )
        )
    }
}

/// The two names as a person types them: the real binary run through a link of each name.
final class CLIBothNamesEndToEndTests: XCTestCase {
    private var directory: URL!
    private var statusURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBothNamesEndToEndTests-\(UUID().uuidString)", isDirectory: true)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try AgentPaths.refreshCLISymlinks(binDirectory: bin, target: AgentPaths.bundledCLIURL)
        statusURL = directory.appendingPathComponent("status.json")
        let snapshot = StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: Date(),
            services: [],
            agents: StatusSnapshot.Agents(needsYou: 0, working: 0, sessions: [])
        )
        try StatusFile.encoder.encode(snapshot).write(to: statusURL, options: [.atomic])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ name: String, _ arguments: [String], stdin input: String? = nil) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = directory.appendingPathComponent("bin/\(name)")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[StatusFile.environmentKey] = statusURL.path
        process.environment = environment
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testBothNamesPrintTheSameStatus() throws {
        let new = try run("brioche", ["status", "--json"])
        let old = try run("omelette", ["status", "--json"])

        XCTAssertEqual(new.status, 0)
        XCTAssertEqual(old.status, 0)
        XCTAssertEqual(new.stdout, old.stdout)
    }

    func testBothNamesServeMCP() throws {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        let new = try run("brioche", ["mcp"], stdin: initialize + "\n")
        let old = try run("omelette", ["mcp"], stdin: initialize + "\n")

        XCTAssertTrue(new.stdout.contains(#""serverInfo""#), new.stdout)
        XCTAssertEqual(new.stdout, old.stdout)
    }
}
