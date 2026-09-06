import Foundation

/// `~/Library/Application Support/UsageTracker/status.json` — what the `omelette`
/// command-line tool reads.
///
/// Split in two on purpose. `build` is a pure function over value types, so every
/// decision about what the CLI will show is made and tested without a disk; the actor
/// does nothing but the write, throttled, so a poll never waits on the file system.
actor StatusFileWriter {
    static let shared = StatusFileWriter()

    /// Two things write this file — the poll, and any change to the agent list — and
    /// the second can fire several times a second while an agent works through a task.
    /// One write every two seconds is faster than any status line redraws.
    static let minimumInterval: TimeInterval = 2

    /// The file is a glance, not a log. Twenty rows is more sessions than anyone has
    /// open, and it keeps a runaway list from turning a 2 KB file into a 200 KB one.
    static let maxSessions = 20

    /// Today's and this week's dollars for one provider, from its own cost log.
    struct CostEntry: Equatable, Sendable {
        var todayCost: Double
        var weekCost: Double
        var todayTokens: Int
    }

    /// The agent list as the file records it. Built on the main actor from
    /// `AgentSessionStore.sessions`, then carried into the write as a value.
    struct AgentSummary: Equatable, Sendable {
        var needsYou: Int
        var working: Int
        var sessions: [StatusSnapshot.Session]

        static let none = AgentSummary(needsYou: 0, working: 0, sessions: [])

        init(needsYou: Int, working: Int, sessions: [StatusSnapshot.Session]) {
            self.needsYou = needsYou
            self.working = working
            self.sessions = sessions
        }

        /// The counts come from the whole list, the rows from the first
        /// `maxSessions` of it — a truncated list must not undercount the flag.
        init(sessions: [AgentSession]) {
            self.needsYou = sessions.reduce(0) { $0 + ($1.state == .needsYou ? 1 : 0) }
            self.working = sessions.reduce(0) { $0 + ($1.state == .working ? 1 : 0) }
            self.sessions = sessions.prefix(StatusFileWriter.maxSessions).map { session in
                StatusSnapshot.Session(
                    id: session.id,
                    project: session.projectName,
                    state: session.state.rawValue,
                    activity: session.activity
                )
            }
        }
    }

    private let fileURL: URL
    private let minimumInterval: TimeInterval
    private var lastWriteAt: Date = .distantPast

    /// Injectable location and throttle — the tests point both at a temp file and zero.
    init(fileURL: URL = StatusFile.defaultURL(), minimumInterval: TimeInterval = StatusFileWriter.minimumInterval) {
        self.fileURL = fileURL
        self.minimumInterval = minimumInterval
    }

    /// Whether a write due `now` may go through. Pure, so the throttle is testable
    /// without a clock and without a file.
    nonisolated static func shouldWrite(
        lastWriteAt: Date, now: Date, minimumInterval: TimeInterval = StatusFileWriter.minimumInterval
    ) -> Bool {
        now.timeIntervalSince(lastWriteAt) >= minimumInterval
    }

    /// Writes unless the last write was too recent. Returns whether the write was
    /// *attempted* — false means only "the throttle swallowed it", which is the
    /// caller's cue to schedule a trailing one so the last change still reaches disk.
    /// An encoding or I/O failure returns true: the next poll carries the same numbers,
    /// and retrying in a tight loop would not fix a full disk.
    @discardableResult
    func write(_ snapshot: StatusSnapshot, now: Date = Date()) -> Bool {
        guard Self.shouldWrite(lastWriteAt: lastWriteAt, now: now, minimumInterval: minimumInterval) else {
            return false
        }
        lastWriteAt = now
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            var data = try StatusFile.encoder.encode(snapshot)
            data.append(0x0A)
            // Foundation's `.atomic` is "write a temp file next door, then rename": a
            // CLI reading mid-write sees the old file whole, never half of the new one.
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[UT] status.json write failed: %@", String(describing: error))
        }
        return true
    }

    /// Pay-as-you-go: an account that reports no rate-limit window of its own. Either
    /// it shows nothing but dollars, or the only "window" is the weekly budget Omelette
    /// invents for it (`AppState.applyPayAsYouGo`). Its dollars are close to the real
    /// bill, so they are *not* an API-equivalent figure — every other account's are.
    nonisolated static func isPayAsYouGo(_ service: ServiceSnapshot) -> Bool {
        let reported = service.buckets.filter { $0.id != AppState.payAsYouGoBudgetBucketID }
        return reported.isEmpty && (service.weekCost ?? 0) > 0
    }

    /// The whole file, from values the app already has. No clock of its own, no disk,
    /// no actor hop: every rule the CLI depends on is decided here.
    nonisolated static func build(
        services: [ServiceSnapshot],
        costs: [String: CostEntry],
        agents: AgentSummary,
        now: Date
    ) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: now,
            services: services.map { service in
                let cost = costs[service.id]
                let today = cost?.todayCost
                let week = cost?.weekCost ?? service.weekCost
                let hasDollars = today != nil || week != nil
                return StatusSnapshot.Service(
                    id: service.id,
                    name: service.displayName,
                    state: service.state.rawValue,
                    retained: service.isRetained,
                    retainedAt: service.retainedAt,
                    plan: service.plan,
                    windows: windows(of: service),
                    todayCost: today,
                    weekCost: week,
                    todayTokens: cost?.todayTokens,
                    apiEquivalent: hasDollars ? !isPayAsYouGo(service) : nil
                )
            },
            agents: StatusSnapshot.Agents(
                needsYou: agents.needsYou, working: agents.working, sessions: agents.sessions
            )
        )
    }

    /// The reported windows, plus the spend limit as one — the popover, the widget and
    /// the notifications all treat an Enterprise spend limit as a real limit, so the
    /// terminal does too (`WidgetBridge.widgetServices`).
    private nonisolated static func windows(of service: ServiceSnapshot) -> [StatusSnapshot.Window] {
        var out = service.buckets.map { bucket in
            StatusSnapshot.Window(
                id: bucket.id,
                label: bucket.label,
                percent: bucket.utilization,
                // `.distantFuture` is the app's spelling of "the provider didn't say".
                resetsAt: bucket.resetsAt < .distantFuture ? bucket.resetsAt : nil,
                kind: bucket.kind.rawValue
            )
        }
        if let extra = service.extraUsage, extra.isEnabled {
            out.append(StatusSnapshot.Window(
                id: "extra_usage",
                label: extraUsageTitle(plan: service.plan),
                percent: extra.utilization,
                resetsAt: nil,
                kind: BucketKind.other.rawValue
            ))
        }
        return out
    }
}
