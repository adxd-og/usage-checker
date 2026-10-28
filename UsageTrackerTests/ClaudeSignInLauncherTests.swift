import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in and The
/// environment: the button opens Terminal running `<claude> auth login` through a `.command`
/// file, not Apple events, and every way that can fail comes back as words. Terminal runs the
/// user's shell startup files first, so the file itself starts Claude Code without
/// `CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`,
/// `CLAUDECODE` and `ANTHROPIC_*`. A harmless stand-in under a path with a space and a quote
/// (the desktop app's copy lives under "Application Support") records what it was given; the
/// file is run with `/bin/sh` here, and Terminal is a closure.
final class ClaudeSignInLauncherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSignInLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stand-in `claude` that writes down its environment and its arguments, one per line in
    /// brackets so an empty one shows, beside itself.
    private func standIn() throws -> URL {
        let folder = directory.appendingPathComponent(
            "Application Support/Claude/claude-code/2.1.308/a b'c/claude.app/Contents/MacOS", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        here="$(/usr/bin/dirname "$0")"
        /usr/bin/env > "$here/seen-env"
        printf '%s\\n' "$#" > "$here/seen-args"
        for argument in "$@"; do printf '[%s]\\n' "$argument" >> "$here/seen-args"; done

        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    private func seenEnvironment(in folder: URL) throws -> [String: String] {
        let text = try String(contentsOf: folder.appendingPathComponent("seen-env"), encoding: .utf8)
        var seen: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return seen
    }

    private let scrubbed = [
        "CLAUDE_CONFIG_DIR": "/elsewhere/cfg",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere/secure",
        "CLAUDE_CODE_OAUTH_TOKEN": "desktop-token",
        "CLAUDECODE": "1",
        "ANTHROPIC_API_KEY": "key",
        "ANTHROPIC_BASE_URL": "https://proxy.invalid",
    ]

    func testTheCommandFileRunsClaudeCodesSignInInACleanEnvironment() throws {
        let binary = try standIn()
        let file = directory.appendingPathComponent("sign-in.command")
        try ClaudeSignInLauncher.commandFile(binary: binary.path).write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        process.environment = scrubbed.merging([
            "PATH": "/usr/bin:/bin", "HOME": directory.path, "OMELETTE_TEST_KEEP": "kept",
        ]) { first, _ in first }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let folder = binary.deletingLastPathComponent()
        let seen = try seenEnvironment(in: folder)
        for key in scrubbed.keys { XCTAssertNil(seen[key], "\(key) reached Claude Code") }
        XCTAssertEqual(seen["OMELETTE_TEST_KEEP"], "kept", "the rest of the shell's environment stays")
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("seen-args"), encoding: .utf8),
            "2\n[auth]\n[login]\n"
        )
    }

    func testAnEqualsSignInThePathStillRunsThatBinary() throws {
        // `env` would take "/…/a=b/claude" for an assignment and run "auth" instead.
        let folder = directory.appendingPathComponent("a=b", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: try standIn(), to: binary)
        let file = directory.appendingPathComponent("sign-in.command")
        try ClaudeSignInLauncher.commandFile(binary: binary.path).write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("seen-args"), encoding: .utf8),
            "2\n[auth]\n[login]\n"
        )
    }

    func testTheFileIsAShellScript() {
        let text = ClaudeSignInLauncher.commandFile(binary: "/usr/local/bin/claude")
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(text.contains("'/usr/local/bin/claude' auth login"))
        XCTAssertFalse(text.contains("osascript"), "not Apple events")
    }

    func testAQuoteInThePathStaysOneArgument() {
        XCTAssertEqual(ClaudeSignInLauncher.shellQuoted("/a b'c/claude"), #"'/a b'\''c/claude'"#)
    }

    @MainActor
    func testTheButtonWritesAnExecutableFileAndHandsItToTerminal() async throws {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        var handed: (file: URL, app: URL)?
        let outcome = await ClaudeSignInLauncher.launch(
            binary: "/usr/local/bin/claude", directory: directory, terminal: terminal,
            open: { file, app in handed = (file, app) }
        )
        XCTAssertEqual(outcome, .opened)
        let file = directory.appendingPathComponent(ClaudeSignInLauncher.fileName)
        XCTAssertEqual(handed?.file, file)
        XCTAssertEqual(handed?.app, terminal)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            ClaudeSignInLauncher.commandFile(binary: "/usr/local/bin/claude")
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
    }

    @MainActor
    func testNoTerminalIsSaidNotSilent() async {
        var opened = false
        let outcome = await ClaudeSignInLauncher.launch(
            binary: "/usr/local/bin/claude", directory: directory, terminal: nil,
            open: { _, _ in opened = true }
        )
        XCTAssertEqual(outcome, .failed(ClaudeSignInCopy.terminalMissing))
        XCTAssertFalse(opened)
    }

    @MainActor
    func testARefusedOpenIsSaidInTheSystemsWords() async {
        let outcome = await ClaudeSignInLauncher.launch(
            binary: "/usr/local/bin/claude", directory: directory,
            terminal: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            open: { _, _ in
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Terminal refused the file."])
            }
        )
        XCTAssertEqual(outcome, .failed("Terminal refused the file."))
    }
}
