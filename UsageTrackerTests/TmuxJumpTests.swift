import XCTest
@testable import Omelette

/// Jumping to a session that runs inside tmux: the address the app jumps with, the
/// branch a click takes, the two tmux calls and the tty the AppleScript is built
/// with. Covers "Design" and "Jump order" in
/// docs/superpowers/specs/2026-09-17-tmux-jump-design.md.
final class TmuxJumpTests: XCTestCase {
    // MARK: - SessionActivator.tmuxTarget

    private func tmuxHost(
        socket: String? = "/private/tmp/tmux-501/default",
        pane: String? = "%3",
        binary: String? = "/opt/homebrew/bin/tmux"
    ) -> AgentHostInfo {
        AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys012",
                      tmuxSocket: socket, tmuxPane: pane, tmuxBinary: binary)
    }

    /// Nothing on this machine is asked about: the test says which paths exist.
    private func exists(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    func testAReportedAddressIsATmuxTarget() {
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: tmuxHost(), binaryExists: exists([])),
            SessionActivator.TmuxTarget(socketPath: "/private/tmp/tmux-501/default",
                                        pane: "%3", binary: "/opt/homebrew/bin/tmux")
        )
    }

    func testWithoutABinaryTheFirstTmuxOnDiskIsUsed() {
        // The helper could not read the server's path (it had gone), so the app
        // guesses — Homebrew first, because that is where a tmux normally lives and
        // a GUI app's PATH has never heard of it.
        XCTAssertEqual(SessionActivator.tmuxBinaryFallbacks,
                       ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: tmuxHost(binary: nil),
                                        binaryExists: exists(["/usr/local/bin/tmux", "/usr/bin/tmux"]))?.binary,
            "/usr/local/bin/tmux"
        )
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: tmuxHost(binary: ""),
                                        binaryExists: exists(["/opt/homebrew/bin/tmux", "/usr/bin/tmux"]))?.binary,
            "/opt/homebrew/bin/tmux"
        )
    }

    func testNoTmuxOnDiskIsNoTarget() {
        // Running a binary we could not find is not a jump.
        XCTAssertNil(SessionActivator.tmuxTarget(for: tmuxHost(binary: nil), binaryExists: exists([])))
    }

    func testHalfAnAddressIsNoTarget() {
        XCTAssertNil(SessionActivator.tmuxTarget(for: tmuxHost(socket: nil), binaryExists: exists([])))
        XCTAssertNil(SessionActivator.tmuxTarget(for: tmuxHost(pane: nil), binaryExists: exists([])))
        XCTAssertNil(SessionActivator.tmuxTarget(for: tmuxHost(socket: ""), binaryExists: exists([])))
        XCTAssertNil(SessionActivator.tmuxTarget(for: tmuxHost(pane: ""), binaryExists: exists([])))
    }

    func testANormalTerminalIsNeverATmuxTarget() {
        let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        XCTAssertNil(SessionActivator.tmuxTarget(for: iterm, binaryExists: exists([])))
        XCTAssertNil(SessionActivator.tmuxTarget(for: .none, binaryExists: exists([])))
    }

    // MARK: - SessionActivator.route

    func testCmuxWinsOverTmux() {
        // tmux started inside cmux inherits the CMUX_* ids into the server's
        // environment, so both addresses ride on the wire — and only cmux can select
        // its own tab.
        var host = tmuxHost()
        host.pid = 900
        host.bundleID = "com.cmuxterm.app"
        host.cmuxWorkspace = "ws-7"
        host.cmuxSurface = "sf-3"
        host.cmuxSocket = "/tmp/cmux.sock"

        XCTAssertEqual(
            SessionActivator.route(for: host, tmuxBinaryExists: exists([])),
            .cmux(SessionActivator.CmuxTarget(workspace: "ws-7", surface: "sf-3", socketPath: "/tmp/cmux.sock"))
        )
    }

    func testTmuxWinsOverAPID() {
        // Under tmux the pid is normally nil, but a pane opened inside a terminal
        // whose app *is* on the chain must still go through tmux: the pid alone would
        // raise the window and leave the wrong pane on screen.
        var host = tmuxHost()
        host.pid = 4242
        host.bundleID = "com.apple.Terminal"

        XCTAssertEqual(
            SessionActivator.route(for: host, tmuxBinaryExists: exists([])),
            .tmux(SessionActivator.TmuxTarget(socketPath: "/private/tmp/tmux-501/default",
                                              pane: "%3", binary: "/opt/homebrew/bin/tmux"))
        )
    }

    func testAnUnusableTmuxAddressFallsBackToWhateverIsLeft() {
        var withPID = tmuxHost(pane: "")
        withPID.pid = 4242
        XCTAssertEqual(SessionActivator.route(for: withPID, tmuxBinaryExists: exists([])), .process(pid: 4242))

        let withoutPID = tmuxHost(pane: "")
        XCTAssertEqual(SessionActivator.route(for: withoutPID, tmuxBinaryExists: exists([])), .finder)
    }

    func testAPlainTerminalRoutesToItsProcessAndNothingRoutesToTheFinder() {
        let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        XCTAssertEqual(SessionActivator.route(for: iterm, tmuxBinaryExists: exists([])), .process(pid: 4242))
        XCTAssertEqual(SessionActivator.route(for: .none, tmuxBinaryExists: exists([])), .finder)
    }

    // MARK: - TmuxJump

    private let target = SessionActivator.TmuxTarget(
        socketPath: "/private/tmp/tmux-501/default", pane: "%3", binary: "/opt/homebrew/bin/tmux"
    )

    /// Records what a jump would have run, so no test ever spawns tmux.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [(binary: String, arguments: [String])] = []
        var all: [(binary: String, arguments: [String])] {
            lock.lock(); defer { lock.unlock() }
            return made
        }
        func record(_ binary: String, _ arguments: [String]) {
            lock.lock(); made.append((binary, arguments)); lock.unlock()
        }
    }

    /// `-S <socket>` is a server option: tmux rejects it after the command name.
    func testTheListClientsCallIsSpelledTheWayTmuxExpects() {
        XCTAssertEqual(
            TmuxJump.listClientsArguments(socketPath: "/private/tmp/tmux-501/default", pane: "%3"),
            ["-S", "/private/tmp/tmux-501/default", "list-clients", "-F",
             "#{client_pid}\t#{client_tty}\t#{client_activity}", "-t", "%3"]
        )
        XCTAssertEqual(TmuxJump.clientFormat, "#{client_pid}\t#{client_tty}\t#{client_activity}")
    }

    /// One call: switch-client selects the session, the window and the pane for that
    /// client in one go.
    func testTheSwitchClientCallNamesTheClientAndThePane() {
        XCTAssertEqual(
            TmuxJump.switchClientArguments(socketPath: "/private/tmp/tmux-501/default",
                                           pane: "%3", clientTTY: "/dev/ttys004"),
            ["-S", "/private/tmp/tmux-501/default", "switch-client", "-c", "/dev/ttys004", "-t", "%3"]
        )
    }

    func testTheMostRecentlyActiveClientWins() {
        // client_activity is a unix timestamp; the user's current window is the
        // largest one. Two terminals attached to one session is the normal case for
        // anyone who ever ran `tmux attach` twice.
        let output = "701\t/dev/ttys004\t1789500000\n902\t/dev/ttys009\t1789600000\n"
        XCTAssertEqual(TmuxJump.pickClient(from: output), TmuxJump.Client(pid: 902, tty: "/dev/ttys009"))
    }

    func testADetachedSessionHasNoClient() {
        XCTAssertNil(TmuxJump.pickClient(from: ""))
        XCTAssertNil(TmuxJump.pickClient(from: "\n\n"))
    }

    func testMalformedLinesAreSkippedRatherThanGuessed() {
        let output = """
        not a client line
        0\t/dev/ttys001\t1789600001
        701\t\t1789600002
        702\t/dev/ttys005\tnot-a-time
        703\t/dev/ttys006\t1789500000
        """
        XCTAssertEqual(TmuxJump.pickClient(from: output), TmuxJump.Client(pid: 703, tty: "/dev/ttys006"))
    }

    func testSelectPaneListsTheClientsThenSwitchesTheMostRecentOne() async {
        let calls = Calls()

        let client = await TmuxJump.selectPane(target) { binary, arguments in
            calls.record(binary, arguments)
            guard arguments.contains("list-clients") else { return "" }
            return "701\t/dev/ttys004\t1789500000\n902\t/dev/ttys009\t1789600000\n"
        }

        XCTAssertEqual(client, TmuxJump.Client(pid: 902, tty: "/dev/ttys009"))
        XCTAssertEqual(calls.all.count, 2)
        XCTAssertEqual(calls.all[0].binary, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(calls.all[0].arguments,
                       ["-S", "/private/tmp/tmux-501/default", "list-clients", "-F",
                        "#{client_pid}\t#{client_tty}\t#{client_activity}", "-t", "%3"])
        XCTAssertEqual(calls.all[1].binary, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(calls.all[1].arguments,
                       ["-S", "/private/tmp/tmux-501/default", "switch-client", "-c", "/dev/ttys009", "-t", "%3"])
    }

    func testNothingAttachedSwitchesNothing() async {
        // A detached session: there is no window to bring forward, so the click falls
        // back to the Finder — and nothing is switched under a user who is not there.
        let calls = Calls()

        let client = await TmuxJump.selectPane(target) { binary, arguments in
            calls.record(binary, arguments)
            return ""
        }

        XCTAssertNil(client)
        XCTAssertEqual(calls.all.count, 1, "nothing is attached, so there is nothing to switch")
    }

    func testATmuxThatCannotBeRunIsSilent() async {
        let client = await TmuxJump.selectPane(target) { _, _ in nil }
        XCTAssertNil(client)
    }

    // MARK: - The script a tmux jump runs

    func testTheScriptIsBuiltWithTheClientTTYNotThePaneTTY() throws {
        // host.tty is the *pane's* tty — the shell inside tmux. No terminal tab has
        // ever had it; the tab that exists belongs to the attached client.
        let paneTTY = try XCTUnwrap(tmuxHost().tty)
        let client = TmuxJump.Client(pid: 701, tty: "/dev/ttys004")

        let source = try XCTUnwrap(SessionActivator.tmuxScript(bundleID: "com.apple.Terminal", client: client))

        XCTAssertTrue(source.contains("\"/dev/ttys004\""), source)
        XCTAssertFalse(source.contains(paneTTY),
                       "the pane's tty must never reach a terminal: \(source)")
        XCTAssertTrue(source.contains("application id \"com.apple.Terminal\""), source)
    }

    func testITermGetsItsOwnScriptWithTheClientTTY() throws {
        let client = TmuxJump.Client(pid: 701, tty: "/dev/ttys011")
        let source = try XCTUnwrap(SessionActivator.tmuxScript(bundleID: "com.googlecode.iterm2", client: client))
        XCTAssertTrue(source.contains("\"/dev/ttys011\""), source)
        XCTAssertTrue(source.contains("sessions of t"), source)
    }

    func testATerminalWithNoAppleScriptGetsNoScript() {
        let client = TmuxJump.Client(pid: 701, tty: "/dev/ttys004")
        XCTAssertNil(SessionActivator.tmuxScript(bundleID: "com.mitchellh.ghostty", client: client))
        XCTAssertNil(SessionActivator.tmuxScript(bundleID: nil, client: client),
                     "the walk found no app, so there is nothing to talk to")
    }
}
