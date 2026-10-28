import XCTest
@testable import Omelette

/// No agy child outlives the quit (spec 2026-10-16-antigravity-argon, the section on fresh
/// numbers while the app is closed: a background run must not outlive the app that
/// started it). `terminateAll()` closes the registry: a run asked for after it starts no
/// child, and a child registered before it but started after it is stopped as it starts.
/// Each test has a registry of its own; the children are `/bin/sh` and `/bin/sleep` in
/// this test's folder. Real processes, real time: every wait keeps at least five times the
/// margin it needs.
final class ChildProcessRegistryQuitTests: XCTestCase {
    private var directory: URL!
    private var strays: [Process] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChildProcessRegistryQuitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for process in strays where process.isRunning { kill(process.processIdentifier, SIGKILL) }
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

    /// `/bin/sleep 30`, not started.
    private func sleeper() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        strays.append(process)
        return process
    }

    func testARunAskedForAfterTheQuitStartsNoChild() async throws {
        let registry = ChildProcessRegistry()
        registry.terminateAll()
        let marker = directory.appendingPathComponent("ran")

        do {
            _ = try await AgyCommand.run(
                executable: "/bin/sh",
                arguments: ["-c", ": > ran"],
                environment: ["PATH": "/usr/bin:/bin"],
                directory: directory,
                deadline: 10,
                killGrace: 0.3,
                registry: registry
            )
            XCTFail("a run after the quit is no reading")
        } catch {
            guard case .launchFailed? = error as? AgyUsageError else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the child never ran")
        XCTAssertEqual(registry.runningCount, 0)
    }

    func testARegistrationAfterTheQuitIsRefused() {
        let registry = ChildProcessRegistry()
        XCTAssertTrue(registry.register(sleeper()), "open before the quit")

        registry.terminateAll()

        XCTAssertFalse(registry.register(sleeper()))
    }

    /// `terminateAll()` signals only a running child, and this one was not running yet:
    /// it is stopped once it has started.
    func testAChildRegisteredBeforeTheQuitAndStartedAfterItIsStopped() async throws {
        let registry = ChildProcessRegistry()
        let child = sleeper()
        XCTAssertTrue(registry.register(child))

        registry.terminateAll()
        try child.run()
        registry.didStart(child)

        let ended = await eventually(within: 3) { !child.isRunning }
        XCTAssertTrue(ended, "SIGTERM as it started, long before its 30 s")
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    func testBeforeTheQuitAStartedChildRunsOn() async throws {
        let registry = ChildProcessRegistry()
        let child = sleeper()
        XCTAssertTrue(registry.register(child))

        try child.run()
        registry.didStart(child)

        let ended = await eventually(within: 0.5) { !child.isRunning }
        XCTAssertFalse(ended)

        registry.terminateAll()
        let stopped = await eventually(within: 3) { !child.isRunning }
        XCTAssertTrue(stopped, "the quit stops it")
    }
}
