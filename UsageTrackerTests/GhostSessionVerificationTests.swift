import XCTest
@testable import Omelette

/// Independent verification of `AgentSessionStore.isStale` / `systemTTYAlive` against
/// the spec: "quiet for ≥ 5 min and its tty has no process attached" is an *addition*
/// to the existing 2h+dead-host rule, not a replacement of it — a session inside the
/// two-hour window must never be dropped just because the host pid happens to be
/// unreachable, as long as its tty is still held. These cases are not in the
/// executor's `GhostSessionTests`.
@MainActor
final class GhostSessionVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        quietFor seconds: TimeInterval,
        pid: Int32? = nil,
        tty: String? = "/dev/ttys004"
    ) -> AgentSession {
        AgentSession(
            sessionID: "s1", source: .claude, projectName: "alpha", cwd: "/tmp/alpha",
            state: .idle, stateSince: t0, lastEventAt: t0, startedAt: t0,
            host: AgentHostInfo(pid: pid, bundleID: "com.googlecode.iterm2", tty: tty),
            turns: 3, needsYouCount: 1
        )
    }

    private func now(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - The two rules really are independent, not "the stricter wins"

    func testADeadHostWithATTYStillAliveAtOneHourFiftyNineIsKept() {
        // Under staleAfter (2h): the dead-pid branch never even runs, and the ghost
        // branch (quiet >= 5 min) says the tty is still held. This is the exact
        // "host pid dead but tty alive at 1:59h" case from the spec's ghost rule.
        XCTAssertFalse(AgentSessionStore.isStale(
            session(quietFor: 0, pid: Int32.max, tty: "/dev/ttys004"),
            now: now(AgentSessionStore.staleAfter - 60),
            ttyAlive: { _ in true }
        ), "a session inside the 2h window must not die just because its host pid looks dead")
    }

    func testADeadHostWithATTYThatHasGoneIsStaleEvenBeforeTwoHours() {
        // The ghost rule (5 min) fires well before the 2h rule would ever get a
        // chance to — the two rules are ORed, not "ghost only after 2h".
        XCTAssertTrue(AgentSessionStore.isStale(
            session(quietFor: 0, pid: Int32.max, tty: "/dev/ttys004"),
            now: now(AgentSessionStore.ghostAfter + 30),
            ttyAlive: { _ in false }
        ))
    }

    func testALiveHostPastTwoHoursWithADeadTTYIsStillAGhost() {
        // Past staleAfter, the pid is alive so the dead-host branch does not fire —
        // but the ghost branch still applies past ghostAfter regardless of how far
        // past it the clock has moved.
        XCTAssertTrue(AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid(), tty: "/dev/ttys004"),
            now: now(AgentSessionStore.staleAfter + 3600),
            ttyAlive: { _ in false }
        ))
    }

    // MARK: - Exactly at the ghostAfter instant (>= , not >)

    func testExactlyFiveMinutesIsAlreadyOldEnoughForTheGhostRule() {
        XCTAssertTrue(AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid(), tty: "/dev/ttys004"),
            now: now(AgentSessionStore.ghostAfter),
            ttyAlive: { _ in false }
        ), "the rule reads '>=', so the boundary instant itself already counts")
    }

    // MARK: - tty: nil never routes through the tty rule, at any quiet duration

    func testANilTTYNeverInvokesTheClosureEvenWellPastBothThresholds() {
        final class Invoked { var called = false }
        let invoked = Invoked()
        _ = AgentSessionStore.isStale(
            session(quietFor: 0, pid: getpid(), tty: nil),
            now: now(AgentSessionStore.staleAfter + AgentSessionStore.ghostAfter + 1),
            ttyAlive: { _ in invoked.called = true; return true }
        )
        XCTAssertFalse(invoked.called, "a session with no tty must fall back to the host-pid rule only")
    }

    // MARK: - The kernel primitive, against a real path

    func testTheSystemProbeSaysNoForAPathThatIsNotACharacterDeviceAtAll() {
        // A regular file: `stat` succeeds, but it is not the kind of node a terminal
        // driver ever hands out as a controlling tty, so the device-number compare
        // against the process table can never match.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostSessionVerificationTests-not-a-tty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(AgentSessionStore.systemTTYAlive(file.path))
    }

    /// A note on what this file does *not* claim: an earlier version of this test
    /// asked `ttyname_r(STDIN_FILENO)` for "this process's own tty" and expected
    /// `systemTTYAlive` to say yes. That assumption is wrong and the investigation is
    /// worth recording. `ttyname_r` on a file descriptor only names the device the fd
    /// happens to point at; it says nothing about whether *this* process is the
    /// session leader that holds that device as its controlling terminal (the
    /// `e_tdev` field `systemTTYAlive` actually reads). Measured directly: when the
    /// xcodebuild-launched test host's own `proc_pidinfo(PROC_PIDTBSDINFO)` was read
    /// for its own pid, `e_tdev` came back `NODEV` (4294967295) even though its stdin
    /// fd resolved to a real `/dev/ttysNNN` — the test host was never made that
    /// terminal's session leader, it only inherited the fd. That is a fact about how
    /// xcodebuild launches a test host, not a bug in `systemTTYAlive`, so the test
    /// below builds a real controlling terminal instead of borrowing xcodebuild's fd.

    func testARealProcessWithItsOwnControllingTerminalReadsAliveThenGoneOnceItExits() throws {
        // `forkpty` gives the child a genuine controlling terminal (it calls setsid +
        // TIOCSCTTY internally) — the one case `ttyname_r(STDIN_FILENO)` above could
        // not manufacture. Every allocation happens *before* the fork: the forked
        // child of this multithreaded XCTest process may not safely call into
        // malloc/Swift runtime locks before it replaces its image, so the child does
        // nothing but `execv` and `_exit`.
        let sleepPath = strdup("/bin/sleep")
        let sleepArg = strdup("30")
        defer { free(sleepPath); free(sleepArg) }
        var argv: [UnsafeMutablePointer<CChar>?] = [sleepPath, sleepArg, nil]

        var masterFD: Int32 = 0
        var nameBuffer = [CChar](repeating: 0, count: 128)
        let pid = forkpty(&masterFD, &nameBuffer, nil, nil)
        guard pid >= 0 else { throw XCTSkip("forkpty unavailable in this environment") }

        if pid == 0 {
            execv(sleepPath, &argv)
            _exit(127)   // execv only returns on failure
        }

        var reaped = false
        func reap() {
            guard !reaped else { return }
            reaped = true
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            close(masterFD)
        }
        defer { reap() }

        let path = String(cString: nameBuffer)
        // Give the child a moment to finish execve and take the terminal.
        for _ in 0..<50 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32(bitPattern: -1) { break }
            usleep(20_000)
        }

        XCTAssertTrue(AgentSessionStore.systemTTYAlive(path),
                      "\(path) is /bin/sleep's controlling terminal right now, pid \(pid) is running")

        reap()
        // Give the kernel a moment to retire the pid from the process table.
        usleep(50_000)

        XCTAssertFalse(AgentSessionStore.systemTTYAlive(path),
                       "the only process on \(path) has been killed and reaped")
    }
}
