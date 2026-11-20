import Foundation

/// CPU and memory per live agent session (spec 2026-11-19 agent resources § Design): which
/// processes are a session's, what its figures are, how often they are read. Pure: the process
/// table, each process's usage and the time come in from outside (`AgentProcessTable` reads the
/// machine, `AgentResourceSampler` keeps the readings, `AgentResourceMonitor` the cadence).
enum AgentResourceRules {
    /// One row of the process table, as `sysctl(KERN_PROC_ALL)` answers it: what the member
    /// rule needs and nothing else.
    struct ProcessRow: Equatable, Sendable {
        let pid: pid_t
        let parent: pid_t
        /// The controlling terminal's path ("/dev/ttys003"), spelled as a session's `host.tty`
        /// is; nil for a process without one (`??` in `ps`).
        let tty: String?
        /// When the process started (`kp_proc.p_starttime`, wall clock): a tty whose every
        /// process started after a session's last event is a newer tab's (Task 4, review F4).
        let startedAt: Date
    }

    /// A session's processes (§ Which processes): every process whose controlling terminal is
    /// `tty`, and every descendant of those by parent pid. A `claude` and its MCP servers keep
    /// the tab's tty; the shells its Bash tool starts have none, and builds and tests hang below
    /// them (measured 2026-11-19), so the tty alone would miss the heaviest work. A process that
    /// detached and was re-parented to launchd is no descendant any more and is not counted.
    /// launchd and the kernel (pid 1 and 0) are never members nor links, whatever the table
    /// says, and a parent cycle ends the walk. Sorted, so equal tables give equal answers.
    static func members(of tty: String, in table: [ProcessRow]) -> [pid_t] {
        guard !tty.isEmpty else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for row in table where row.pid > 1 {
            children[row.parent, default: []].append(row.pid)
        }
        var found = Set<pid_t>()
        var queue = table.filter { $0.pid > 1 && $0.tty == tty }.map(\.pid)
        while let pid = queue.popLast() {
            guard found.insert(pid).inserted else { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return found.sorted()
    }
}
