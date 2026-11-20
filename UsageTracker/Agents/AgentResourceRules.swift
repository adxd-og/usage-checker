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

// MARK: - Figures (spec § Figures)

extension AgentResourceRules {
    /// One process's cumulative CPU time and physical footprint, as `proc_pid_rusage` answers
    /// for the user's own processes (`AgentProcessTable.usage`).
    struct Usage: Equatable, Sendable {
        /// User and system seconds, as Task 1's ruling counts them (R2).
        let cpuSeconds: Double
        /// `ri_phys_footprint`: what Activity Monitor's Memory column shows.
        let footprintBytes: Int
    }

    /// One tty's processes at one moment: each member's CPU seconds, their footprints summed,
    /// and when the oldest member started.
    struct Reading: Equatable, Sendable {
        let at: Date
        let cpuSeconds: [pid_t: Double]
        let footprintBytes: Int
        /// The earliest `startedAt` among every member, those `usage` refused included.
        let oldestStart: Date?
    }

    /// What a session shows and the wire carries. `cpuPercent` is per core, 100 being one core
    /// as Activity Monitor counts it, and nil until a second reading. `oldestStart` is never
    /// shown: it decides whether the tty's tree is still the session's (Task 4); nil in a figure
    /// built by hand.
    struct Figures: Equatable, Sendable {
        let cpuPercent: Double?
        let memoryBytes: Int
        var oldestStart: Date? = nil
    }

    /// Two readings further apart than this are no pair: the Mac slept, or no session had a tty
    /// for a while. The newer one then shows memory and no CPU, as a first reading does.
    static let maximumSpan: TimeInterval = 120

    /// `tty`'s reading at `now`: one `usage` call per member. A member `usage` answers nil for —
    /// another user's process (root's `login` on every Terminal tab), or one gone since the table
    /// was read — is skipped. nil when no member answered: nothing was measured. A negative or
    /// non-finite counter reads as zero and footprints add up saturating, so a wild value is a
    /// wrong figure, never a trap.
    static func reading(
        of tty: String, in table: [ProcessRow], usage: (pid_t) -> Usage?, at now: Date
    ) -> Reading? {
        let started = Dictionary(table.map { ($0.pid, $0.startedAt) }, uniquingKeysWith: { first, _ in first })
        let pids = members(of: tty, in: table)
        var cpu: [pid_t: Double] = [:]
        var footprint = 0
        for pid in pids {
            guard let used = usage(pid) else { continue }
            cpu[pid] = used.cpuSeconds.isFinite ? max(0, used.cpuSeconds) : 0
            let (sum, overflow) = footprint.addingReportingOverflow(max(0, used.footprintBytes))
            footprint = overflow ? Int.max : sum
        }
        guard !cpu.isEmpty else { return nil }
        return Reading(
            at: now, cpuSeconds: cpu, footprintBytes: footprint,
            oldestStart: pids.compactMap { started[$0] }.min()
        )
    }

    /// What `current` shows after `previous` (§ Figures): memory as it is now; CPU from a second
    /// reading on; the tty's oldest start, for the reused-tty rule.
    static func figures(previous: Reading?, current: Reading) -> Figures {
        Figures(
            cpuPercent: cpuPercent(previous: previous, current: current),
            memoryBytes: current.footprintBytes,
            oldestStart: current.oldestStart
        )
    }

    /// CPU per core between two readings: the seconds gained over the seconds between, × 100.
    /// nil without a previous reading, or when the span is not positive or longer than
    /// `maximumSpan`. Never negative.
    static func cpuPercent(previous: Reading?, current: Reading) -> Double? {
        guard let previous else { return nil }
        let span = current.at.timeIntervalSince(previous.at)
        guard span > 0, span <= maximumSpan else { return nil }
        // Outcome A (Task 1): a process's total holds its reaped children's time, so a child that
        // exits moves its time into its parent's and the session's total runs on. A total that
        // went down (a process left the tree) gives 0 %.
        let gained = current.cpuSeconds.values.reduce(0, +) - previous.cpuSeconds.values.reduce(0, +)
        return max(0, gained) / span * 100
    }
}
