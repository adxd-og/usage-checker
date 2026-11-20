import Foundation

/// Reads every live session's tty in one pass (spec 2026-11-19 agent resources § Which
/// processes, § Sampling): one snapshot of the process table per sample, indexed once
/// (`AgentResourceRules.ProcessIndex`, spec 2026-11-20 small backlog 2 § F), answers for all of
/// them, then one `usage` call per member. An actor, so the reading never runs on the main
/// actor; it keeps each tty's last reading for the next CPU figure. The table, `usage`, the
/// core count that caps a CPU figure and the index are injected; the app's are
/// `AgentProcessTable`'s, the Mac's active processor count and `ProcessIndex.init`.
actor AgentResourceSampler {
    /// A tty read less than this long ago is not read again; its figures stand. Opening the
    /// island samples at once, and two opens in a row must not divide by a sliver of a second.
    static let minimumSpan: TimeInterval = 2

    private let table: @Sendable () -> [AgentResourceRules.ProcessRow]
    private let usage: @Sendable (pid_t) -> AgentResourceRules.Usage?
    private let cores: Int
    private let index: @Sendable ([AgentResourceRules.ProcessRow]) -> AgentResourceRules.ProcessIndex
    private var readings: [String: AgentResourceRules.Reading] = [:]
    private var figures: [String: AgentResourceRules.Figures] = [:]

    init(
        table: @escaping @Sendable () -> [AgentResourceRules.ProcessRow] = { AgentProcessTable.read() },
        usage: @escaping @Sendable (pid_t) -> AgentResourceRules.Usage? = { AgentProcessTable.usage($0) },
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        index: @escaping @Sendable ([AgentResourceRules.ProcessRow]) -> AgentResourceRules.ProcessIndex = {
            AgentResourceRules.ProcessIndex($0)
        }
    ) {
        self.table = table
        self.usage = usage
        self.cores = cores
        self.index = index
    }

    /// The figures of every tty in `ttys` with a member that answers, as of `now`. A tty no
    /// longer asked for is forgotten, so it starts again from memory alone if it comes back.
    /// Nothing is read when `ttys` is empty or every tty was read less than `minimumSpan` ago; a
    /// clock that went back reads at once.
    func sample(ttys: Set<String>, now: Date) -> [String: AgentResourceRules.Figures] {
        readings = readings.filter { ttys.contains($0.key) }
        figures = figures.filter { ttys.contains($0.key) }
        let due = ttys.filter { tty in
            guard let previous = readings[tty] else { return true }
            let span = now.timeIntervalSince(previous.at)
            return span >= Self.minimumSpan || span < 0
        }
        guard !due.isEmpty else { return figures }
        let indexed = index(table())
        for tty in due {
            guard let current = AgentResourceRules.reading(of: tty, in: indexed, usage: usage, at: now) else {
                readings[tty] = nil
                figures[tty] = nil
                continue
            }
            figures[tty] = AgentResourceRules.figures(previous: readings[tty], current: current, cores: cores)
            readings[tty] = current
        }
        return figures
    }
}
