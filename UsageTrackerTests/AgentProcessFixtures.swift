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

extension AgentProcessFixture {
    /// Activity Monitor's megabyte.
    static let mb = 1_048_576

    /// What `proc_pid_rusage` answers at `t0`: CPU seconds and footprint in MB. Root's `login`
    /// (500, 600) is refused, as pid 1 was on the probe of 2026-11-19, so it has no entry.
    static let usageAt0: [pid_t: AgentResourceRules.Usage] = [
        501: usage(1.5, 2), 502: usage(4469.2, 634), 503: usage(12.0, 90), 504: usage(3.0, 20),
        510: usage(0.4, 3), 511: usage(8.0, 300), 512: usage(2.0, 150), 513: usage(5.0, 700),
        601: usage(0.9, 2), 602: usage(120.0, 410), 610: usage(0.1, 3),
        701: usage(0.7, 2), 702: usage(300.0, 520), 710: usage(0.2, 3), 711: usage(0.3, 2),
    ]

    /// Five seconds later, nobody gone: claude +1.0, node +0.5, xcodebuild +1.0, clang +2.5,
    /// swift-frontend +6.6 = 11.6 s; swift-frontend's footprint 700 → 900 MB.
    static let usageAt1: [pid_t: AgentResourceRules.Usage] = usageAt0.merging([
        502: usage(4470.2, 634), 503: usage(12.5, 90), 511: usage(9.0, 300),
        512: usage(4.5, 150), 513: usage(11.6, 900),
    ]) { _, new in new }

    /// clang (512) has exited and xcodebuild (511) has reaped it.
    static let tableAfterClang = table.filter { $0.pid != 512 }
    /// Later, swift-frontend (513) has exited too.
    static let tableAfterSwiftFrontend = tableAfterClang.filter { $0.pid != 513 }

    static func usage(_ seconds: Double, _ megabytes: Int) -> AgentResourceRules.Usage {
        AgentResourceRules.Usage(cpuSeconds: seconds, footprintBytes: megabytes * mb)
    }
}

extension AgentProcessFixture {
    /// Outcome A, five seconds after `usageAt1`: clang ran 0.5 s more and exited; xcodebuild ran
    /// 0.5 s itself and holds clang's whole 5.0 s as reaped time: 9.0 + 0.5 + 5.0 = 14.5. claude
    /// +1.0, swift-frontend +2.0. What the session gained: 1.0 + 0.5 + 0.5 + 2.0 = 4.0 s.
    static let usageAt2Reaped: [pid_t: AgentResourceRules.Usage] = usageAt1.merging([
        502: usage(4471.2, 634), 511: usage(14.5, 300), 513: usage(13.6, 900),
    ]) { _, new in new }

    /// Outcome A, five seconds later still (table `tableAfterSwiftFrontend`): xcodebuild started
    /// and reaped a compiler that ran 1.2 s between the two readings, and reaped swift-frontend,
    /// which ran 0.4 s more and exited: 14.5 + 1.2 + (13.6 + 0.4) = 29.7. Gained: 1.2 + 0.4 = 1.6 s.
    static let usageAt3Reaped: [pid_t: AgentResourceRules.Usage] = usageAt2Reaped.merging([
        511: usage(29.7, 300),
    ]) { _, new in new }
}

/// The machine as the sampler sees it, set by a test: the table and every process's usage,
/// changed between samples, and how often the table was read and on which thread.
final class FakeMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [AgentResourceRules.ProcessRow]
    private var usages: [pid_t: AgentResourceRules.Usage]
    private var reads = 0
    private var readsOnMain = 0

    init(
        table: [AgentResourceRules.ProcessRow] = AgentProcessFixture.table,
        usage: [pid_t: AgentResourceRules.Usage] = AgentProcessFixture.usageAt0
    ) {
        rows = table
        usages = usage
    }

    func set(table: [AgentResourceRules.ProcessRow]? = nil, usage: [pid_t: AgentResourceRules.Usage]? = nil) {
        lock.withLock {
            if let table { rows = table }
            if let usage { usages = usage }
        }
    }

    var tableReads: Int { lock.withLock { reads } }
    var tableReadsOnMain: Int { lock.withLock { readsOnMain } }

    func readTable() -> [AgentResourceRules.ProcessRow] {
        lock.withLock {
            reads += 1
            if Thread.isMainThread { readsOnMain += 1 }
            return rows
        }
    }

    func usage(_ pid: pid_t) -> AgentResourceRules.Usage? {
        lock.withLock { usages[pid] }
    }

    func sampler() -> AgentResourceSampler {
        AgentResourceSampler(table: { self.readTable() }, usage: { self.usage($0) })
    }
}
