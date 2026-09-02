import Foundation
import Combine

/// Every agent session the app knows about, and what each one is doing right now.
///
/// Two feeds arrive here. Hook events (`apply`) are precise: Claude Code tells us a
/// prompt was submitted, a tool started, an approval is waiting. The passive scan
/// (`mergePassive`) is approximate and only fills in sessions no hook has spoken
/// for. Hook state always wins for a session id we have heard from.
@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared = AgentSessionStore()

    /// Sorted for display: `needsYou` first, then `working`, `done`, `idle`
    /// (`AgentState.rank`), and inside a group the most recently active first.
    @Published private(set) var sessions: [AgentSession] = []
    /// When the last hook event of any kind arrived — Settings shows it as a
    /// liveness signal for the socket.
    @Published private(set) var lastEventAt: Date?

    /// Fires when a session *enters* `needsYou` — once per episode, so a
    /// `PermissionRequest` immediately followed by its `Notification` fallback is one
    /// notification, not two.
    var onNeedsYou: ((AgentSession) -> Void)?
    /// Fires when a session *enters* `done`, same once-per-episode rule.
    var onDone: ((AgentSession) -> Void)?

    var needsYouCount: Int { sessions.reduce(0) { $0 + ($1.state == .needsYou ? 1 : 0) } }
    var workingCount: Int { sessions.reduce(0) { $0 + ($1.state == .working ? 1 : 0) } }

    /// A hook-tracked session with no event for this long and no live host process is
    /// assumed dead (`pruneStale`).
    static let staleAfter: TimeInterval = 2 * 3600

    private let history: AgentHistoryStore

    /// Injectable history location — the tests point it at a temp file instead of
    /// `~/Library/Application Support/UsageTracker/agent-sessions.jsonl`.
    init(historyURL: URL = AgentPaths.historyURL) {
        self.history = AgentHistoryStore(fileURL: historyURL)
    }

    /// `"claude:<session_id>"` — a Claude session and a Codex thread could in
    /// principle carry the same uuid, so the source is part of the identity.
    /// One spelling for everyone: `AgentSession` builds its own `id` the same way,
    /// which is what makes a passive row and a hook row collide instead of doubling.
    static func identifier(source: AgentSource, sessionID: String) -> String {
        AgentSession.makeID(source: source, sessionID: sessionID)
    }

    func sessions(for source: AgentSource) -> [AgentSession] {
        sessions.filter { $0.source == source }
    }

    // MARK: - Hook events

    func apply(_ event: AgentEvent, now: Date = Date()) {
        // Subagents are a session's internals, not sessions of their own: a Task tool
        // running five agents must not put five rows in the popover.
        guard !event.isSubagent else { return }
        // Timestamps come from our own clock rather than `event.receivedAt`: the list
        // is sorted by them, and a message that waited in the socket queue must not
        // sort ahead of one that arrived after it.
        lastEventAt = now

        let id = Self.identifier(source: event.source, sessionID: event.sessionID)

        if case .sessionEnd = event.kind {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            let ended = sessions.remove(at: index)
            archive(ended, endedAt: now)
            return
        }

        let existing = sessions.first(where: { $0.id == id })
        // An event we don't model, for a session we've never seen, tells us nothing
        // worth a row — all we would have is an id.
        if case .unknown = event.kind, existing == nil { return }

        var session = existing ?? makeSession(from: event, now: now)
        let previousState: AgentState? = existing?.state

        if let cwd = event.cwd, !cwd.isEmpty {
            session.cwd = cwd
            session.projectName = ProjectName.display(path: cwd)
        }
        if event.host.pid != nil || event.host.bundleID != nil || event.host.tty != nil {
            session.host = event.host
        }
        // A hook has spoken for this id, so whatever the passive scan guessed is
        // superseded from here on.
        session.isApproximate = false
        session.lastEventAt = now

        switch event.kind {
        case .sessionStart:
            transition(&session, to: .idle, now: now)
        case .promptSubmitted:
            session.turns += 1
            session.activity = nil
            transition(&session, to: .working, now: now)
        case .toolStarted, .toolFinished:
            // PostToolUse carries no tool_input, so it usually has no summary; the
            // one from PreToolUse stays on screen until the next tool starts.
            if let summary = event.toolSummary { session.activity = summary }
            transition(&session, to: .working, now: now)
        case .permissionRequested, .notificationPermission:
            if let summary = event.toolSummary { session.activity = summary }
            transition(&session, to: .needsYou, now: now)
        case .notificationIdle:
            transition(&session, to: .idle, now: now)
        case .stop, .codexTurnComplete:
            transition(&session, to: .done, now: now)
        case .unknown:
            break // lastEventAt is already refreshed; the state is left alone.
        case .sessionEnd:
            break // handled above
        }

        if session.state == .needsYou, previousState != .needsYou {
            session.needsYouCount += 1
        }
        upsert(session)
        sortSessions()

        if session.state != previousState {
            switch session.state {
            case .needsYou: onNeedsYou?(session)
            case .done: onDone?(session)
            case .working, .idle: break
            }
        }
    }

    // MARK: - Private

    private func makeSession(from event: AgentEvent, now: Date) -> AgentSession {
        AgentSession(
            sessionID: event.sessionID,
            source: event.source,
            projectName: Self.projectName(for: event.cwd),
            cwd: event.cwd,
            state: .idle,
            activity: nil,
            stateSince: now,
            lastEventAt: now,
            startedAt: now,
            host: event.host,
            isApproximate: false,
            turns: 0,
            needsYouCount: 0
        )
    }

    static func projectName(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Unknown project" }
        return ProjectName.display(path: cwd)
    }

    /// `stateSince` is what the UI counts up from ("working 4m"), so it moves only on
    /// a real change: five tool events in a row are one stretch of working.
    private func transition(_ session: inout AgentSession, to state: AgentState, now: Date) {
        guard session.state != state else { return }
        session.state = state
        session.stateSince = now
    }

    private func upsert(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    /// State group first, then most recent activity, then id so the order is stable
    /// when two sessions share a timestamp (they do: one poll merges many at once).
    private func sortSessions() {
        sessions.sort { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.id < b.id
        }
    }

    /// A session leaves the list into the history log. Approximate (passive) sessions
    /// are dropped without a record: their `turns` is 0 and their `startedAt` is only
    /// when we first noticed the file, so writing them would put numbers in the
    /// phase-3 history that never happened.
    private func archive(_ session: AgentSession, endedAt: Date) {
        guard !session.isApproximate else { return }
        let record = AgentSessionRecord(
            id: session.id,
            source: session.source,
            project: session.projectName,
            startedAt: session.startedAt,
            endedAt: endedAt,
            turns: session.turns,
            needsYouCount: session.needsYouCount
        )
        do {
            try history.append(record)
        } catch {
            NSLog("[UT] agent history append failed: %@", String(describing: error))
        }
    }
}
