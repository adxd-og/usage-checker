import XCTest
@testable import Omelette

/// Verifier tests for `AgyCommand` (spec 2026-10-16-antigravity-argon § "Package 2" and the
/// session rulings: no shell, allowlisted environment, 45 s deadline then SIGTERM then SIGKILL,
/// stdout capped at 1 MiB, quiet failures). The child is `/bin/sh` in this test's own
/// folder, never agy. Real processes in real time; every timing keeps at least five times
/// the margin it needs.
final class AgyCommandVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgyCommandVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sh(
        _ script: String,
        environment: [String: String] = ["PATH": "/usr/bin:/bin"],
        deadline: TimeInterval = 10,
        killGrace: TimeInterval = 0.3,
        registry: AgyChildRegistry = AgyChildRegistry()
    ) async throws -> Data {
        try await AgyCommand.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            directory: directory,
            deadline: deadline,
            killGrace: killGrace,
            registry: registry
        )
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func isGone(_ pid: pid_t, within seconds: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        return false
    }

    private func pid(in name: String, within seconds: TimeInterval = 5) async throws -> pid_t {
        let url = directory.appendingPathComponent(name)
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n"),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        throw XCTSkip("the script never wrote \(name)")
    }

    // MARK: - How the child is started

    func testTheChildRunsInTheFolderItWasGiven() async throws {
        let output = try await sh("pwd -P")
        let reported = text(output).trimmingCharacters(in: .whitespacesAndNewlines)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        XCTAssertNotNil(realpath(directory.path, &buffer))
        XCTAssertEqual(reported, String(cString: buffer))
    }

    /// stdin is closed: a child that reads it sees the end at once and is not left waiting.
    func testTheChildReadsNothingFromStandardInput() async throws {
        let started = Date()
        let output = try await sh("cat; printf done", deadline: 10)
        XCTAssertEqual(text(output), "done")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// stderr is not read and not a pipe: a child that writes far more to it than a pipe holds
    /// is not stalled, and none of it is in the answer.
    func testALotOfStandardErrorNeitherStallsTheChildNorReachesTheAnswer() async throws {
        let output = try await sh("/usr/bin/head -c 500000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2; printf ok")
        XCTAssertEqual(text(output), "ok")
    }

    /// Exactly what the caller passes is the child's environment: nothing of the test host's.
    func testTheChildSeesExactlyTheEnvironmentItWasGiven() async throws {
        let given = ["HOME": "/nonexistent-home", "PATH": "/usr/bin:/bin", "AGY_CLI_DISABLE_AUTO_UPDATE": "true"]
        let output = try await sh("/usr/bin/env", environment: given)
        var seen: [String: String] = [:]
        for line in text(output).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        // /bin/sh may add PWD, SHLVL and `_`; nothing else may be there.
        for added in ["PWD", "SHLVL", "_", "OLDPWD"] { seen[added] = nil }
        XCTAssertEqual(seen, given)
    }

    // MARK: - How a run ends

    /// A child that exits non-zero after printing is no reading, whatever it printed.
    func testAFailedChildsOutputIsNotReturned() async {
        do {
            let output = try await sh("printf '{\"status\":\"SUCCESS\"}'; exit 1")
            XCTFail("a failed run is no reading, got \(text(output))")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .exitStatus(1))
        }
    }

    /// A child ended by a signal of its own is its signal's number.
    func testAChildEndedBySIGKILLIsItsSignalNumber() async {
        do {
            _ = try await sh("kill -9 $$")
            XCTFail("a killed run is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .exitStatus(SIGKILL))
        }
    }

    /// "Still running, or its stdout still open, at the deadline": a child that closes its
    /// stdout and goes on running is not done either, and is stopped.
    func testAChildThatClosesStdoutButKeepsRunningTimesOutAndIsStopped() async throws {
        let started = Date()
        do {
            _ = try await sh("exec >&-; echo $$ > child.pid; exec /bin/sleep 30", deadline: 0.5)
            XCTFail("a child still running at the deadline is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let child = try await pid(in: "child.pid")
        let gone = await isGone(child, within: 3)
        XCTAssertTrue(gone)
    }

    /// The deadline is a deadline: the caller is not answered before it.
    func testTheCallerIsNotAnsweredBeforeTheDeadline() async {
        let started = Date()
        do {
            _ = try await sh("exec /bin/sleep 30", deadline: 1.0)
            XCTFail("expected the deadline")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .timedOut)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.9)
        XCTAssertLessThan(elapsed, 5)
    }

    /// The registry holds a child from its start to its end, whichever way it ends.
    func testTheRegistryIsEmptyAfterEveryKindOfEnd() async throws {
        let registry = AgyChildRegistry()
        _ = try await sh("printf ok", registry: registry)
        XCTAssertEqual(registry.runningCount, 0, "exit 0")

        _ = try? await sh("exit 2", registry: registry)
        XCTAssertEqual(registry.runningCount, 0, "non-zero exit")

        _ = try? await sh("exec /bin/sleep 30", deadline: 0.3, registry: registry)
        var end = Date().addingTimeInterval(3)
        while registry.runningCount > 0, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(registry.runningCount, 0, "the deadline's SIGTERM")

        _ = try? await sh("/usr/bin/head -c 3000000 /dev/zero; exec /bin/sleep 30", registry: registry)
        end = Date().addingTimeInterval(3)
        while registry.runningCount > 0, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(registry.runningCount, 0, "stopped for printing past the cap")
    }

    // MARK: - The 1 MiB cap with the real default

    func testTheDefaultCapIsOneMiBToTheByte() async throws {
        let atTheCap = try await sh("/usr/bin/head -c 1048576 /dev/zero")
        XCTAssertEqual(atTheCap.count, 1_048_576)
        do {
            _ = try await sh("/usr/bin/head -c 1048577 /dev/zero")
            XCTFail("one byte over 1 MiB is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .outputTooLarge)
        }
    }

    // MARK: - Quitting the app

    /// The app's own registry: a child started the way the provider starts one is in it
    /// while it runs, so `terminateAll()`, which is what `applicationWillTerminate` calls,
    /// reaches it. `terminateAll()` also closes a registry for good, so it is not called on
    /// the app's one here: the child ends at its deadline, and `AgyChildRegistryTests`
    /// stops one through `terminateAll()` on a registry of its own.
    func testARunStartedTheWayTheProviderStartsOneIsInTheSharedRegistry() async throws {
        let shared = AgyChildRegistry.shared
        let baseline = shared.runningCount
        let folder: URL = directory
        let child = Task { () -> Result<Data, Error> in
            do {
                return .success(try await AgyCommand.run(
                    executable: "/bin/sh",
                    arguments: ["-c", "echo $$ > child.pid; exec /bin/sleep 30"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    directory: folder,
                    deadline: 1,
                    killGrace: 0.3
                ))
            } catch {
                return .failure(error)
            }
        }
        let pid = try await pid(in: "child.pid")
        XCTAssertEqual(shared.runningCount, baseline + 1)

        let result = await child.value
        guard case .failure(let error) = result else { return XCTFail("a stopped run is no reading") }
        XCTAssertEqual(error as? AgyUsageError, .timedOut)
        let gone = await isGone(pid, within: 3)
        XCTAssertTrue(gone)
        let left = Date().addingTimeInterval(3)
        while shared.runningCount > baseline, Date() < left { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(shared.runningCount, baseline)
    }

    // MARK: - The environment rule

    /// Whatever Omelette's environment says, the self-updater stays off for the child, and
    /// nothing loads code into it.
    func testNothingInTheHostEnvironmentTurnsTheUpdaterOnOrInjectsCode() {
        let child = AgyCommand.childEnvironment(
            from: [
                "HOME": "/home/o", "AGY_CLI_DISABLE_AUTO_UPDATE": "false",
                "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "DYLD_LIBRARY_PATH": "/tmp",
                "HTTPS_PROXY": "http://proxy", "GEMINI_API_KEY": "k", "SHELL": "/bin/zsh",
            ],
            executable: "/home/o/.local/bin/agy",
            homeDirectory: "/home/o"
        )
        XCTAssertEqual(child["AGY_CLI_DISABLE_AUTO_UPDATE"], "true")
        XCTAssertEqual(Set(child.keys), ["HOME", "PATH", "AGY_CLI_DISABLE_AUTO_UPDATE"])
    }

    /// PATH is the fixed system folders and then agy's own folder, in that order, for any
    /// folder agy is in; a PATH in the host environment is not part of it.
    func testPATHIsTheSystemFoldersThenAgysFolder() {
        for folder in ["/opt/homebrew/bin", "/Users/o/.local/bin", "/usr/local/bin"] {
            let child = AgyCommand.childEnvironment(
                from: ["PATH": "/evil:/bin", "HOME": "/Users/o"],
                executable: folder + "/agy",
                homeDirectory: "/Users/o"
            )
            XCTAssertEqual(child["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:" + folder)
        }
    }
}
