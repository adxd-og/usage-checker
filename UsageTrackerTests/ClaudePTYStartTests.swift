import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Renewal through Claude Code
/// and The environment: Omelette starts the unmodified Claude Code on a terminal of its own and
/// types nothing into it — a keystroke could answer a first-run screen and change the user's
/// settings — with the scrubbed environment plus `DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY`,
/// `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, the renewal mark, and `USER`, `HOME` and the login
/// shell's `PATH` (verification (2): without `USER` Claude Code cannot find its keychain item).
/// A stand-in under a path with a space and a quote records what it was given.
final class ClaudePTYStartTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudePTYStartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ script: String, executable: Bool = true) throws -> URL {
        let folder = directory.appendingPathComponent(
            "Application Support/Claude/claude-code/2.1.308/a b'c/claude.app/Contents/MacOS", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path)
        return binary
    }

    /// Records its environment, arguments, folder and whether stdin is a terminal, then reads
    /// the terminal raw, byte by byte, into `seen-typed` until it is stopped.
    private let recordingStandIn = """
    #!/bin/sh
    here="$(/usr/bin/dirname "$0")"
    /usr/bin/env > "$here/seen-env"
    printf '%s\\n' "$#" > "$here/seen-args"
    for argument in "$@"; do printf '[%s]\\n' "$argument" >> "$here/seen-args"; done
    /bin/pwd -P > "$here/seen-cwd"
    if [ -t 0 ]; then echo yes > "$here/seen-tty"; fi
    /bin/stty raw -echo
    exec /bin/cat > "$here/seen-typed"

    """

    private let base = [
        "PATH": "/usr/bin:/bin",
        "CLAUDE_CONFIG_DIR": "/elsewhere/cfg",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere/secure",
        "CLAUDE_CODE_OAUTH_TOKEN": "desktop-token",
        "CLAUDECODE": "1",
        "ANTHROPIC_API_KEY": "key",
        "ANTHROPIC_BASE_URL": "https://proxy.invalid",
        "OMELETTE_TEST_KEEP": "kept",
    ]

    private func read(_ name: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - The environment rule

    func testTheRenewalEnvironmentDropsWhatPointsElsewhereAndAddsItsOwn() {
        let environment = ClaudeCLIEnvironment.renewal(base: base, loginPATH: nil, home: "/test-home", user: "tester")
        for key in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN",
                    "CLAUDECODE", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"] {
            XCTAssertNil(environment[key], key)
        }
        XCTAssertEqual(environment["OMELETTE_TEST_KEEP"], "kept")
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(environment["DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(environment[ClaudeRenewalMarker.environmentKey], ClaudeRenewalMarker.value)
        XCTAssertTrue(ClaudeRenewalMarker.isRenewal(environment: environment))
        XCTAssertFalse(ClaudeRenewalMarker.isRenewal(environment: base))
        XCTAssertEqual(environment["TERM"], "xterm-256color")
    }

    func testItAlwaysCarriesUserAndHome() {
        let filled = ClaudeCLIEnvironment.renewal(base: base, loginPATH: nil, home: "/test-home", user: "tester")
        XCTAssertEqual(filled["USER"], "tester", "Claude Code finds its keychain item only with USER set")
        XCTAssertEqual(filled["HOME"], "/test-home")
        let kept = ClaudeCLIEnvironment.renewal(
            base: base.merging(["USER": "owner", "HOME": "/Users/owner"]) { first, _ in first },
            loginPATH: nil, home: "/test-home", user: "tester"
        )
        XCTAssertEqual(kept["USER"], "owner")
        XCTAssertEqual(kept["HOME"], "/Users/owner")
    }

    func testThePATHIsTheLoginShellsFirstEachFolderOnce() {
        XCTAssertEqual(
            ClaudeCLIEnvironment.path(loginPATH: ["/Users/tester/.nvm/versions/node/v24/bin", "/usr/bin"], base: "/usr/bin:/bin"),
            "/Users/tester/.nvm/versions/node/v24/bin:/usr/bin:/bin"
        )
        XCTAssertEqual(ClaudeCLIEnvironment.path(loginPATH: nil, base: nil), "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // MARK: - The start

    func testTheStartGetsItsEnvironmentArgumentsFolderAndATerminalAndNothingIsTyped() async throws {
        let binary = try write(recordingStandIn)
        let probe = directory.appendingPathComponent("probe folder", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let environment = ClaudeCLIEnvironment.renewal(
            base: base, loginPATH: ["/opt/test/bin", "/usr/bin"], home: directory.path, user: "tester"
        )

        try await ClaudePTYStart.run(
            binary: binary.path,
            arguments: ["--allowed-tools", "", "--strict-mcp-config"],
            environment: environment,
            directory: probe,
            duration: 1.5,
            grace: 1
        )

        let folder = binary.deletingLastPathComponent()
        let seen = try read("seen-env", in: folder)
        XCTAssertTrue(seen.contains("\nPATH=/opt/test/bin:/usr/bin:/bin\n") || seen.hasPrefix("PATH=/opt/test/bin:/usr/bin:/bin\n"), seen)
        XCTAssertTrue(seen.contains("USER=tester\n"), seen)
        XCTAssertTrue(seen.contains("HOME=\(directory.path)\n"), seen)
        XCTAssertTrue(seen.contains("DISABLE_AUTOUPDATER=1\n"), seen)
        XCTAssertTrue(seen.contains("DISABLE_TELEMETRY=1\n"), seen)
        XCTAssertTrue(seen.contains("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1\n"), seen)
        XCTAssertTrue(seen.contains("\(ClaudeRenewalMarker.environmentKey)=1\n"), seen)
        XCTAssertFalse(seen.contains("CLAUDE_CONFIG_DIR="), seen)
        XCTAssertFalse(seen.contains("ANTHROPIC_"), seen)
        XCTAssertFalse(seen.contains("CLAUDE_CODE_OAUTH_TOKEN="), seen)
        XCTAssertEqual(try read("seen-args", in: folder), "3\n[--allowed-tools]\n[]\n[--strict-mcp-config]\n")
        // `pwd -P` reports the folder as the file system has it (`realpath(3)`): the temp
        // folder's `/var` is `/private/var`, which `resolvingSymlinksInPath()` strips again.
        let physical = try XCTUnwrap(realpath(probe.path, nil))
        defer { free(physical) }
        XCTAssertEqual(
            try read("seen-cwd", in: folder).trimmingCharacters(in: .newlines),
            String(cString: physical)
        )
        XCTAssertEqual(try read("seen-tty", in: folder), "yes\n", "a terminal, so Claude Code starts its interface")
        XCTAssertEqual(try read("seen-typed", in: folder), "", "Omelette typed nothing")
    }

    func testAProgramThatEndsByItselfIsNotWaitedFor() async throws {
        let binary = try write("#!/bin/sh\nexit 0\n")
        let started = Date()
        try await ClaudePTYStart.run(
            binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            directory: directory, duration: 10, grace: 1
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAProgramThatCannotStartIsALaunchFailure() async throws {
        let binary = try write("#!/bin/sh\nexit 0\n", executable: false)
        do {
            try await ClaudePTYStart.run(
                binary: binary.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                directory: directory, duration: 1, grace: 1
            )
            XCTFail("a file that cannot run did not throw")
        } catch let failure as ClaudePTYStart.Failure {
            guard case .launch = failure else { return XCTFail("\(failure)") }
        }
    }

    /// `waitUntilExit()` from a task missed the exit now and then and never returned (2 of 5
    /// stress runs of 80 starts, 2026-10-28). Many short starts of a program that ignores
    /// SIGTERM and floods its terminal must all come back; a regression fails here on the
    /// timeout instead of hanging the suite.
    func testManyStartsInARowAllComeBack() async throws {
        let flood = directory.appendingPathComponent("flood.sh")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done\n"
            .write(to: flood, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flood.path)
        let folder = directory!
        let finished = expectation(description: "every start came back")
        Task.detached {
            for _ in 0..<25 {
                try? await ClaudePTYStart.run(
                    binary: flood.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                    directory: folder, duration: 0.05, grace: 0.05
                )
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 60)
    }
}
