import Combine
import Foundation

/// CPU and memory of every live agent session with a tty (spec 2026-11-19 agent resources
/// § Sampling): a loop that asks `AgentResourceSampler` — an actor, so the process table is never
/// read on the main actor — every 5 s while the island or the Agents tab is open, every 30 s
/// otherwise, and that does not run at all while no live session has a tty. A change of the
/// ttys or of the open surfaces restarts it with a sample at once; the sampler skips a tty read
/// less than two seconds before. A surface is open while any of its view instances says so, each
/// by its own token, so a view that leaves late cannot switch off the one that replaced it. The
/// island, the Agents tab and `status.json` read `bySession`.
@MainActor
final class AgentResourceMonitor: ObservableObject {
    static let shared = AgentResourceMonitor()

    /// The surfaces that ask for the 5-second cadence while they are on screen.
    enum Watcher: Hashable, Sendable {
        case island, agentsTab
    }

    /// The last sample's figures by tty. Empty while no live session has a tty. Not published:
    /// everything that shows a figure reads `bySession`.
    private(set) var byTTY: [String: AgentResourceRules.Figures] = [:]
    /// The figures each live session shows, by session id (`AgentResourceRules.bySession`): its
    /// tty's, for the most recently active session on that tty only, and only while the tree is
    /// its own. Follows the session list at once, between samples too.
    @Published private(set) var bySession: [String: AgentResourceRules.Figures] = [:]

    private let sampler: AgentResourceSampler
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var ttys: Set<String> = []
    /// The live list as the store last sent it: `bySession` is decided over the whole of it.
    private var sessions: [AgentSession] = []
    /// The view instances that hold each surface open, by the token each view owns.
    private var watchers: [Watcher: Set<UUID>] = [:]
    /// The one loop that samples, nil while there is none. Only `restart()` writes it, and it
    /// cancels the loop it replaces first, so two loops never sample side by side.
    private var loop: Task<Void, Never>?
    private var sessionsObserver: AnyCancellable?

    /// Everything that touches the machine or the clock comes in; the app's are the defaults.
    /// `sleep` has to return when its task is cancelled, as `Task.sleep` does: that is how a
    /// replaced loop leaves its wait.
    init(
        sampler: AgentResourceSampler = AgentResourceSampler(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.sampler = sampler
        self.now = now
        self.sleep = sleep
    }

    /// How often the loop samples now; nil while it does not run.
    var cadence: TimeInterval? {
        AgentResourceRules.interval(ttys: ttys.count, watched: isWatched)
    }

    var isSampling: Bool { loop != nil }

    private var isWatched: Bool { watchers.values.contains { !$0.isEmpty } }

    /// Follows the session list. `@Published` sends the new list before the store holds it, so
    /// the sent list is the one read.
    func follow(_ sessions: Published<[AgentSession]>.Publisher) {
        sessionsObserver = sessions.sink { [weak self] sessions in
            MainActor.assumeIsolated { self?.update(sessions: sessions) }
        }
    }

    /// The live sessions changed: which session shows each tty's figures is decided again at
    /// once; the loop restarts only when the set of their ttys changed.
    func update(sessions: [AgentSession]) {
        self.sessions = sessions
        refreshBySession()
        let wanted = AgentResourceRules.ttys(of: sessions)
        guard wanted != ttys else { return }
        ttys = wanted
        restart()
    }

    /// One view instance of the island or the Agents tab came on screen, or left it. `token` is
    /// the view's own (a `UUID` in its `@State`): a surface stays watched while any of its views
    /// holds it, so a late `false` from a replaced view leaves its replacement watched. A view
    /// counts once however often it says `true`, and a `false` from a view that holds nothing
    /// releases nothing. The loop restarts only when the surfaces' watched state as a whole
    /// changes.
    func setWatching(_ watcher: Watcher, by token: UUID, _ watching: Bool) {
        let wasWatched = isWatched
        var tokens = watchers[watcher, default: []]
        if watching { tokens.insert(token) } else { tokens.remove(token) }
        watchers[watcher] = tokens.isEmpty ? nil : tokens
        guard isWatched != wasWatched else { return }
        restart()
    }

    /// Cancels the running loop and starts the one the ttys and the watchers call for: a sample
    /// now, then one per cadence. With no tty there is no loop and there are no figures.
    ///
    /// The loop runs on the main actor and leaves it only inside its two awaits. Cancelling
    /// happens here, on the main actor too, so the loop's check after the sample and its publish
    /// are one step nothing can come between: a sample that was in flight when the loop was
    /// replaced or stopped is dropped, never published. A loop cancelled in its sleep returns
    /// from it and ends at the `while`.
    private func restart() {
        loop?.cancel()
        loop = nil
        guard let interval = cadence else {
            byTTY = [:]
            refreshBySession()
            return
        }
        let sampler = self.sampler
        let now = self.now
        let sleep = self.sleep
        let ttys = self.ttys
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let figures = await sampler.sample(ttys: ttys, now: now())
                // A cancelled loop publishes nothing; a monitor that has gone ends its loop.
                guard !Task.isCancelled, self?.publish(figures) != nil else { return }
                await sleep(interval)
            }
        }
    }

    private func publish(_ figures: [String: AgentResourceRules.Figures]) {
        byTTY = figures
        refreshBySession()
    }

    private func refreshBySession() {
        let shown = AgentResourceRules.bySession(sessions, byTTY: byTTY)
        if shown != bySession { bySession = shown }
    }
}
