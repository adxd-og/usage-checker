import Foundation
@testable import Omelette

/// A process table shaped like the one measured on 2026-11-19 (spec 2026-11-19 agent resources,
/// Facts): a `claude` and its MCP servers on the tab's tty under root's `login`, the shell its
/// Bash tool starts with no tty and a build below it; a daemon the build left behind,
/// re-parented to launchd; a second tab; a tmux server with two panes; launchd and the kernel.
/// The pids are made up; the shapes are the measured ones. Every process started an hour
/// before `t0` but the first tab's `login`, which opened the tab two hours before.
enum AgentProcessFixture {
    /// 2026-11-19 12:00:00 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_795_089_600)
    /// When the first tab opened: its root `login` started then.
    static let tabOpened = t0.addingTimeInterval(-7200)
    /// When every other process started.
    static let processStart = t0.addingTimeInterval(-3600)

    static let tab = "/dev/ttys003"
    static let otherTab = "/dev/ttys004"
    static let pane = "/dev/ttys005"
    static let otherPane = "/dev/ttys006"
    static let closedTab = "/dev/ttys009"

    static let table: [AgentResourceRules.ProcessRow] = [
        row(0, 0, nil),            // kernel_task
        row(1, 0, nil),            // launchd
        row(400, 1, nil),          // Terminal
        // The first tab: root's login, the user's shell, claude and its MCP servers keep the tty …
        row(500, 400, tab, started: tabOpened),  // login (root)
        row(501, 500, tab),        // -zsh
        row(502, 501, tab),        // claude
        row(503, 502, tab),        // node, an MCP server
        row(504, 502, tab),        // mcpbridge
        // … the Bash tool's shell has none, and the build hangs below it.
        row(510, 502, nil),        // /bin/zsh
        row(511, 510, nil),        // xcodebuild
        row(512, 511, nil),        // clang
        row(513, 511, nil),        // swift-frontend
        // A daemon the build started, re-parented to launchd: no longer the session's.
        row(520, 1, nil),
        // The second tab.
        row(600, 400, otherTab),   // login (root)
        row(601, 600, otherTab),   // -zsh
        row(602, 601, otherTab),   // claude
        row(610, 602, nil),        // its Bash tool's shell
        // tmux: the server is launchd's; each pane's shell is the server's.
        row(700, 1, nil),          // tmux server
        row(701, 700, pane),       // the pane's shell
        row(702, 701, pane),       // claude
        row(710, 702, nil),        // its Bash tool's shell
        row(711, 700, otherPane),  // another pane's shell
    ]

    static func row(
        _ pid: pid_t, _ parent: pid_t, _ tty: String?, started: Date = processStart
    ) -> AgentResourceRules.ProcessRow {
        AgentResourceRules.ProcessRow(pid: pid, parent: parent, tty: tty, startedAt: started)
    }
}
