import XCTest
@testable import Omelette

/// The parent walk, on a process table that is a dictionary. Covers the walk the
/// hook has always done (`omelette-hook ← sh ← claude ← zsh ← login ← iTermServer ←
/// iTerm2`) and the tmux case the jump spec is about: under tmux the chain ends at
/// the server with no app on it.
/// Spec: docs/superpowers/specs/2026-09-17-tmux-jump-design.md, "Design", step 3.
final class HostWalkTests: XCTestCase {
    private func reader(_ table: [pid_t: ProcessRecord]) -> (pid_t) -> ProcessRecord? {
        { table[$0] }
    }

    func testTheInnermostKnownTerminalIsReportedWithItsOutermostPID() {
        // iTerm2's session lives under iTermServer; both carry the same bundle id and
        // the pid worth activating is the outer one.
        let table: [pid_t: ProcessRecord] = [
            10: ProcessRecord(parentPID: 9, tty: "/dev/ttys004", bundleID: nil),   // omelette-hook
            9: ProcessRecord(parentPID: 8, tty: "/dev/ttys004", bundleID: nil),    // sh
            8: ProcessRecord(parentPID: 7, tty: "/dev/ttys004", bundleID: nil),    // claude
            7: ProcessRecord(parentPID: 6, tty: "/dev/ttys004", bundleID: nil),    // zsh
            6: ProcessRecord(parentPID: 5, tty: nil, bundleID: nil),               // login
            5: ProcessRecord(parentPID: 4, tty: nil, bundleID: "com.googlecode.iterm2"),
            4: ProcessRecord(parentPID: 1, tty: nil, bundleID: "com.googlecode.iterm2"),
        ]

        let terminal = HostWalk.describe(from: 10, read: reader(table))

        XCTAssertEqual(terminal.pid, 4, "the outermost process of the same app, not its helper")
        XCTAssertEqual(terminal.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(terminal.tty, "/dev/ttys004")
    }

    func testWithoutAKnownTerminalTheOutermostAppAncestorIsReported() {
        // Something with a bundle id is better than nothing: a click can still
        // activate it.
        let table: [pid_t: ProcessRecord] = [
            20: ProcessRecord(parentPID: 19, tty: "/dev/ttys009", bundleID: nil),
            19: ProcessRecord(parentPID: 18, tty: "/dev/ttys009", bundleID: "com.example.InnerHelper"),
            18: ProcessRecord(parentPID: 1, tty: nil, bundleID: "com.example.OuterApp"),
        ]

        let terminal = HostWalk.describe(from: 20, read: reader(table))

        XCTAssertEqual(terminal.pid, 18)
        XCTAssertEqual(terminal.bundleID, "com.example.OuterApp")
    }

    func testUnderTmuxTheWalkEndsAtTheServerWithNoHost() {
        // The whole reason this package exists: the pane's shell hangs off the tmux
        // server, which launchd started, so there is no app anywhere on the chain.
        let table: [pid_t: ProcessRecord] = [
            30: ProcessRecord(parentPID: 29, tty: "/dev/ttys012", bundleID: nil),  // omelette-hook
            29: ProcessRecord(parentPID: 28, tty: "/dev/ttys012", bundleID: nil),  // claude
            28: ProcessRecord(parentPID: 27, tty: "/dev/ttys012", bundleID: nil),  // the pane's zsh
            27: ProcessRecord(parentPID: 1, tty: nil, bundleID: nil),              // tmux server
        ]

        let terminal = HostWalk.describe(from: 30, read: reader(table))

        XCTAssertNil(terminal.pid)
        XCTAssertNil(terminal.bundleID)
        XCTAssertEqual(terminal.tty, "/dev/ttys012", "the pane's tty, which is not the terminal's")
    }

    func testTheFirstControllingTerminalSeenIsTheOneReported() {
        let table: [pid_t: ProcessRecord] = [
            50: ProcessRecord(parentPID: 49, tty: "/dev/ttys004", bundleID: nil),
            49: ProcessRecord(parentPID: 1, tty: "/dev/ttys099", bundleID: "com.apple.Terminal"),
        ]

        XCTAssertEqual(HostWalk.describe(from: 50, read: reader(table)).tty, "/dev/ttys004")
    }

    func testTheWalkStopsAtThirtyTwoHops() {
        // A cycle or a pathological chain must end the walk, not the process table.
        var table: [pid_t: ProcessRecord] = [:]
        for pid in pid_t(2)...pid_t(80) {
            table[pid] = ProcessRecord(parentPID: pid + 1, tty: nil,
                                       bundleID: pid == 40 ? "com.apple.Terminal" : nil)
        }

        let terminal = HostWalk.describe(from: 2, read: reader(table))

        XCTAssertEqual(HostWalk.maxHops, 32)
        XCTAssertNil(terminal.bundleID, "a terminal 38 hops up is past the cap")
    }

    func testAProcessTableThatAnswersNothingIsNoHost() {
        let terminal = HostWalk.describe(from: 99, read: { _ in nil })
        XCTAssertNil(terminal.pid)
        XCTAssertNil(terminal.bundleID)
        XCTAssertNil(terminal.tty)
    }

    func testCmuxCountsAsAKnownTerminal() {
        for bundleID in HostWalk.cmuxBundleIDs {
            XCTAssertTrue(HostWalk.knownBundleIDs.contains(bundleID), bundleID)
        }
        XCTAssertTrue(HostWalk.knownBundleIDs.contains("com.apple.Terminal"))
        XCTAssertTrue(HostWalk.knownBundleIDs.contains("com.googlecode.iterm2"))
        XCTAssertTrue(HostWalk.knownBundleIDs.contains("com.mitchellh.ghostty"))
    }
}
