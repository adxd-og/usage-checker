import XCTest
@testable import Omelette

/// `AgyCommand.run` (spec 2026-10-16-antigravity-argon § "Package 2", Design: a hard
/// deadline, the child stopped when it overstays, no shell; session rulings A3, A5, A6:
/// the stdout reader is closed at the deadline, signals go only to a running child,
/// stdout is capped at 1 MiB). The child is `/bin/sh` or a stub script in this test's own
/// folder, never agy. These tests run real processes in real time; every timing
/// assertion keeps at least five times the margin it needs.
final class AgyCommandRunTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgyCommandRunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `script` under `/bin/sh -c`, in this test's folder.
    private func sh(_ script: String, deadline: TimeInterval = 10, killGrace: TimeInterval = 0.3) async throws -> Data {
        try await AgyCommand.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: directory,
            deadline: deadline,
            killGrace: killGrace
        )
    }

    /// The pid a script wrote to `name` in this test's folder.
    private func pid(in name: String) throws -> pid_t {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Whether `pid` is gone (exited and reaped) within `seconds`.
    private func isGone(_ pid: pid_t, within seconds: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        return false
    }

    /// The text of `name` in this test's folder once a script has written it, nil if it
    /// has not within `seconds`.
    private func contents(of name: String, within seconds: TimeInterval) async -> String? {
        let url = directory.appendingPathComponent(name)
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n") {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < end
        return nil
    }

    func testStdoutComesBackWhenTheChildExitsZero() async throws {
        let output = try await sh("printf 'agy says hi'")
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "agy says hi")
    }

    func testALargeOutputComesBackWhole() async throws {
        // More than a pipe holds: stdout is drained while the child runs.
        let output = try await sh("/usr/bin/head -c 200000 /dev/zero")
        XCTAssertEqual(output.count, 200_000)
    }

    func testANonZeroExitIsItsStatus() async {
        do {
            _ = try await sh("exit 3")
            XCTFail("a failed run is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .exitStatus(3))
        }
    }

    func testAMissingExecutableIsALaunchFailure() async {
        do {
            _ = try await AgyCommand.run(
                executable: directory.appendingPathComponent("no-such-agy").path,
                arguments: [],
                environment: [:],
                directory: directory,
                deadline: 10,
                killGrace: 0.3
            )
            XCTFail("nothing to start is no reading")
        } catch {
            guard case .launchFailed? = error as? AgyUsageError else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }

    func testTheDeadlineAnswersTheCallerAndTerminatesTheChild() async throws {
        let started = Date()
        do {
            _ = try await sh("echo $$ > child.pid; exec /bin/sleep 30", deadline: 0.5)
            XCTFail("a child that outlives the deadline is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the caller is answered at the deadline")
        let child = try pid(in: "child.pid")
        let gone = await isGone(child, within: 3)
        XCTAssertTrue(gone, "SIGTERM at the deadline ends the child")
    }

    func testAChildThatIgnoresSIGTERMIsKilledAfterTheGrace() async throws {
        let started = Date()
        do {
            _ = try await sh("trap '' TERM; echo $$ > child.pid; exec /bin/sleep 30", deadline: 0.5, killGrace: 0.3)
            XCTFail("a child that outlives the deadline is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the caller does not wait for the grace")
        let child = try pid(in: "child.pid")
        let gone = await isGone(child, within: 3)
        XCTAssertTrue(gone, "SIGKILL follows when SIGTERM did not end it")
    }

    func testAGrandchildHoldingStdoutDoesNotHoldTheCaller() async throws {
        // The shell exits at once; the sleep it leaves behind keeps stdout open.
        let started = Date()
        do {
            _ = try await sh("/bin/sleep 30 & echo $! > grandchild.pid; exit 0", deadline: 0.5)
            XCTFail("stdout still open at the deadline is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let grandchild = try pid(in: "grandchild.pid")
        _ = kill(grandchild, SIGKILL)
    }

    /// At the deadline the reader lets go of stdout (ruling A3): a process still holding
    /// it finds nobody reading, and no reader is left blocked on it. The grandchild writes
    /// at 1.5 s, five times the deadline, with SIGPIPE ignored so the failed write is
    /// what it reports (the shell's own `printf` checks its write, in a subshell of its
    /// own so its unwritten byte stays there).
    func testTheDeadlineClosesTheStdoutReader() async throws {
        let script = """
        ( trap '' PIPE; /bin/sleep 1.5; if ( printf x ); then echo open > wrote; else echo closed > wrote; fi ) &
        exit 0
        """
        do {
            _ = try await sh(script, deadline: 0.3)
            XCTFail("stdout still open at the deadline is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .timedOut)
        }
        let wrote = await contents(of: "wrote", within: 10)
        XCTAssertEqual(wrote, "closed", "after the deadline nobody reads the child's stdout")
    }

    /// Ruling A6: at most 1 MiB of stdout is kept. Exactly the cap is a whole answer.
    func testOutputUpToTheCapComesBackWhole() async throws {
        let output = try await sh("/usr/bin/head -c 1048576 /dev/zero")
        XCTAssertEqual(output.count, 1_048_576)
    }

    func testOneByteOverTheCapIsNoReading() async {
        do {
            _ = try await sh("/usr/bin/head -c 1048577 /dev/zero")
            XCTFail("output over the cap is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .outputTooLarge)
        }
    }

    func testAChildThatKeepsWritingPastTheCapIsStopped() async throws {
        do {
            _ = try await sh("echo $$ > child.pid; exec /bin/cat /dev/zero")
            XCTFail("output over the cap is no reading")
        } catch {
            XCTAssertEqual(error as? AgyUsageError, .outputTooLarge, "answered at the cap, long before the deadline")
        }
        let child = try pid(in: "child.pid")
        let gone = await isGone(child, within: 3)
        XCTAssertTrue(gone, "the child is terminated at the cap")
    }

    func testTheDeadlineIsFortyFiveSecondsTheGraceFiveAndTheCapOneMiB() {
        XCTAssertEqual(AgyCommand.deadline, 45)
        XCTAssertEqual(AgyCommand.killGrace, 5)
        XCTAssertEqual(AgyCommand.outputLimit, 1_048_576)
    }
}
