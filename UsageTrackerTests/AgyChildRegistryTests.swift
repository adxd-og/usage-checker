import XCTest
@testable import Omelette

/// `AgyChildRegistry` (session ruling A4 on spec 2026-10-16-antigravity-argon § "Package 2":
/// a background agy run does not outlive the app; on quit every running child gets
/// SIGTERM). The rule is tested on a registry of the test's own, with `/bin/sh` children
/// in this test's folder; the app delegate only calls `AgyChildRegistry.shared.terminateAll()`.
/// Real processes, real time: every wait keeps at least five times the margin it needs.
final class AgyChildRegistryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgyChildRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether `condition` holds within `seconds`.
    private func eventually(within seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        return condition()
    }

    func testQuittingTerminatesARunningChild() async throws {
        let registry = AgyChildRegistry()
        let folder: URL = directory
        let pidFile = folder.appendingPathComponent("child.pid")
        let run = Task {
            try await AgyCommand.run(
                executable: "/bin/sh",
                arguments: ["-c", "echo $$ > child.pid; exec /bin/sleep 30"],
                environment: ["PATH": "/usr/bin:/bin"],
                directory: folder,
                deadline: 20,
                killGrace: 0.3,
                registry: registry
            )
        }
        let started = await eventually(within: 5) {
            registry.runningCount == 1 && FileManager.default.fileExists(atPath: pidFile.path)
        }
        XCTAssertTrue(started, "a started child is registered")

        registry.terminateAll()

        do {
            _ = try await run.value
            XCTFail("a child ended by the quit is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .exitStatus(SIGTERM), "SIGTERM ended it, long before its deadline")
        }
        XCTAssertEqual(registry.runningCount, 0, "an exited child is no longer registered")
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try XCTUnwrap(pid_t(text))
        let gone = await eventually(within: 3) { kill(child, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(gone)
    }

    func testAFinishedChildIsNoLongerRegistered() async throws {
        let registry = AgyChildRegistry()
        let output = try await AgyCommand.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf done"],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: directory,
            deadline: 10,
            killGrace: 0.3,
            registry: registry
        )
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "done")
        XCTAssertEqual(registry.runningCount, 0)
        registry.terminateAll() // nothing left to signal
    }

    func testAChildThatNeverStartedIsNotRegistered() async {
        let registry = AgyChildRegistry()
        do {
            _ = try await AgyCommand.run(
                executable: directory.appendingPathComponent("no-such-agy").path,
                arguments: [],
                environment: [:],
                directory: directory,
                deadline: 10,
                killGrace: 0.3,
                registry: registry
            )
            XCTFail("nothing to start is no reading")
        } catch {
            XCTAssertEqual(registry.runningCount, 0)
        }
    }
}
