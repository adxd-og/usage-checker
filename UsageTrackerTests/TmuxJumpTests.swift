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
}
