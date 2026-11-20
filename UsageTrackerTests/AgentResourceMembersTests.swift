import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Which processes: a session's processes are every process
/// whose controlling terminal is the session's tty, and every descendant of those; a process
/// re-parented to launchd is not counted. The table is shaped like the one measured on
/// 2026-11-19 (`AgentProcessFixture`).
final class AgentResourceMembersTests: XCTestCase {
    private typealias F = AgentProcessFixture

    func testASessionsProcessesAreItsTTYsAndEveryDescendant() {
        XCTAssertEqual(
            AgentResourceRules.members(of: F.tab, in: F.table),
            [500, 501, 502, 503, 504, 510, 511, 512, 513],
            "login, the shell, claude, its MCP servers, its Bash tool's shell and the build below it"
        )
    }

    func testAnotherTabsProcessesAreNotCounted() {
        XCTAssertEqual(AgentResourceRules.members(of: F.otherTab, in: F.table), [600, 601, 602, 610])
    }

    func testAProcessReparentedToLaunchdIsNotCounted() {
        XCTAssertFalse(AgentResourceRules.members(of: F.tab, in: F.table).contains(520))
    }

    func testUnderTmuxOnlyThePanesTreeCounts() {
        XCTAssertEqual(
            AgentResourceRules.members(of: F.pane, in: F.table), [701, 702, 710],
            "not the tmux server, not the other pane"
        )
    }

    func testATTYNoProcessHoldsHasNoMembers() {
        XCTAssertEqual(AgentResourceRules.members(of: F.closedTab, in: F.table), [])
    }

    func testAnEmptyTTYMatchesNothing() {
        let table = F.table + [F.row(530, 1, "")]
        XCTAssertEqual(AgentResourceRules.members(of: "", in: table), [])
    }

    func testLaunchdAndTheKernelAreNeverMembers() {
        let tty = "/dev/ttys007"
        let table = [F.row(0, 0, tty), F.row(1, 0, tty), F.row(900, 1, nil)]
        XCTAssertEqual(
            AgentResourceRules.members(of: tty, in: table), [],
            "one row on a tty must never pull in every daemon"
        )
    }

    func testAParentCycleEndsTheWalk() {
        let tty = "/dev/ttys008"
        let table = [F.row(800, 801, tty), F.row(801, 800, nil)]
        XCTAssertEqual(AgentResourceRules.members(of: tty, in: table), [800, 801])
    }
}
