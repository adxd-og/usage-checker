import XCTest
@testable import Omelette

/// Where agy logs a background `/usage` run (spec 2026-10-16-antigravity-argon, the
/// section on fresh numbers while the app is closed: a run every few minutes in the
/// background). Without `--log-file` each run leaves a new `cli-<time>.log` in agy's own
/// log folder, which agy never prunes; with it, agy writes only the file it is given and
/// starts it over on each run (measured on 2026-10-17). The stub agy lives in this test's
/// folder and the log folder is injected, so no test touches Omelette's real one.
final class AgyLogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgyLogFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stub `agy` in `bin/` under this test's folder: `body` after a `#!/bin/sh` line.
    private func stubAgy(_ body: String) throws -> URL {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("agy")
        try ("#!/bin/sh\n" + body + "\n").write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func fetch(stub: URL, logDirectory: URL) async throws -> Data {
        try await AgyCommand.fetch(
            environment: ["PATH": stub.deletingLastPathComponent().path],
            homeDirectory: directory.path,
            keychainState: { .unlocked },
            directory: directory,
            logDirectory: logDirectory
        )
    }

    func testAgyIsToldToLogToOmelettesOwnFileBeforeTheUsageCommand() async throws {
        let stub = try stubAgy(#"printf '%s\n' "$@""#)
        let logs = directory.appendingPathComponent("Application Support/UsageTracker", isDirectory: true)

        let output = try await fetch(stub: stub, logDirectory: logs)

        XCTAssertEqual(
            String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init),
            ["--log-file", logs.appendingPathComponent("agy-usage.log").path, "-p", "/usage", "--output-format", "json"],
            "one argument per word, the path whole though it holds a space"
        )
    }

    func testTheLogFolderIsMadeWhenItIsMissing() async throws {
        // The stub writes its log where it was told to, as agy does; it cannot make a folder.
        let stub = try stubAgy(#"printf 'run\n' > "$2" && printf ok"#)
        let logs = directory.appendingPathComponent("not-yet/UsageTracker", isDirectory: true)

        let output = try await fetch(stub: stub, logDirectory: logs)

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "ok")
        let log = try String(contentsOf: logs.appendingPathComponent("agy-usage.log"), encoding: .utf8)
        XCTAssertEqual(log, "run\n")
    }

    func testEveryRunLogsToTheSameFile() async throws {
        let stub = try stubAgy(#"printf 'run\n' >> "$2""#)
        let logs = directory.appendingPathComponent("logs", isDirectory: true)

        _ = try await fetch(stub: stub, logDirectory: logs)
        _ = try await fetch(stub: stub, logDirectory: logs)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: logs.path), ["agy-usage.log"])
    }

    /// A run that never starts makes no folder: the keychain is checked first.
    func testALockedKeychainMakesNoLogFolder() async throws {
        let stub = try stubAgy("printf ok")
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        do {
            _ = try await AgyCommand.fetch(
                environment: ["PATH": stub.deletingLastPathComponent().path],
                homeDirectory: directory.path,
                keychainState: { .locked },
                directory: directory,
                logDirectory: logs
            )
            XCTFail("a locked keychain is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .keychainLocked)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
    }

    /// The folder the app logs agy to unless told otherwise: its own Application Support
    /// folder, the one `HistoryStore` and the status file use. Worked out, never touched.
    func testByDefaultAgyLogsIntoOmelettesApplicationSupportFolder() {
        XCTAssertEqual(AgyCommand.defaultLogDirectory, AgentPaths.appSupportURL)
        XCTAssertTrue(AgyCommand.defaultLogDirectory.path.hasSuffix("/Library/Application Support/UsageTracker"))
    }
}
