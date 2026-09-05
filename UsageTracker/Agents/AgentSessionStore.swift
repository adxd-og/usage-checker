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

    /// Sessions a `SessionEnd` hook has closed, with when. The transcript stays
    /// inside the passive scan's window for a while after the CLI quits; without
    /// this the next poll would resurrect the row as "≈ Idle".
    private var endedIDs: [String: Date] = [:]
    /// `AgentSession.id` → request id of the permission Omelette is holding for it.
    /// Kept beside the rows because the broker registers a request *before* the
    /// event that creates the row is applied (see `AppState.bootstrap`).
    private var pendingPermissionIDs: [String: String] = [:]
    /// Matches the passive scan's `recentWindow`: once the file has aged out of
    /// the scan there is nothing left to suppress.
    static let endedTombstoneTTL: TimeInterval = 30 * 60

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

    // MARK: - Pending permission (phase 4)

    /// Records which permission request is held for `sessionID` (nil = none). The
    /// broker is the only caller. Publishes only when the row actually changes.
    func setPendingPermission(id: String?, for sessionID: String) {
        if let id {
            pendingPermissionIDs[sessionID] = id
        } else {
            pendingPermissionIDs.removeValue(forKey: sessionID)
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].pendingPermissionID != id else { return }
        sessions[index].pendingPermissionID = id
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
            endedIDs[id] = now
            pendingPermissionIDs.removeValue(forKey: id)
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
            session.activityDetail = nil
            session.attention = nil
            transition(&session, to: .working, now: now)
        case .toolStarted, .toolFinished:
            if event.kind == .toolFinished, Self.clearsAttention(event.toolName) {
                // The answer has been typed. The row stops asking and goes quiet
                // until the next tool starts.
                session.attention = nil
                session.activity = nil
                session.activityDetail = nil
                transition(&session, to: .working, now: now)
            } else if event.kind == .toolStarted, let attention = event.attention {
                session.attention = attention
                Self.applyActivity(event, to: &session)
                transition(&session, to: .needsYou, now: now)
            } else if session.attention == nil {
                Self.applyActivity(event, to: &session)
                transition(&session, to: .working, now: now)
            }
            // A session waiting on a question keeps showing the question: anything
            // else the agent runs meanwhile is its own business, not the answer.
        case .permissionRequested, .notificationPermission:
            Self.applyActivity(event, to: &session)
            transition(&session, to: .needsYou, now: now)
        case .notificationIdle:
            transition(&session, to: .idle, now: now)
        case .stop, .codexTurnComplete:
            session.attention = nil
            transition(&session, to: .done, now: now)
        case .unknown:
            break // lastEventAt is already refreshed; the state is left alone.
        case .sessionEnd:
            break // handled above — the row is gone, attention with it
        }

        if session.state == .needsYou, previousState != .needsYou {
            session.needsYouCount += 1
        }
        // The broker is the only authority on a held permission: it clears the id when
        // the hold ends, whatever the terminal did. Tool events can arrive *during* a
        // hold (Claude Code runs pre-approved calls alongside the one that is waiting),
        // and the buttons must not vanish while the banner is still up. Only
        // `sessionEnd` (above) forgets the id on its own.
        session.pendingPermissionID = pendingPermissionIDs[id]
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

    // MARK: - Passive scan

    /// Folds one `PassiveSessionScanner` result into the list.
    ///
    /// Precedence: a session id a hook has spoken for is never rewritten by a file
    /// mtime — the hook knows whether the agent is waiting for you, the file only
    /// knows that bytes were appended. The single exception is Codex, which has no
    /// "turn started" hook at all: a rollout file that changed in the last 30 seconds
    /// is the only evidence its agent is running again, so it may lift a Codex session
    /// out of `done`/`idle` into `working`.
    ///
    /// Passive-only sessions mirror the scan exactly: added when they appear, updated
    /// while they are in it, dropped when they fall out of the 30-minute window.
    func mergePassive(_ scanned: [AgentSession], now: Date = Date()) {
        let scannedByID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [AgentSession] = []
        merged.reserveCapacity(max(sessions.count, scanned.count))

        for existing in sessions {
            guard existing.isApproximate else {
                merged.append(upgradedIfCodexIsWorking(existing, scannedByID[existing.id], now: now))
                continue
            }
            guard var fresh = scannedByID[existing.id] else { continue } // gone from the scan
            fresh.startedAt = min(existing.startedAt, fresh.startedAt)
            if fresh.state == existing.state {
                fresh.stateSince = existing.stateSince
            }
            merged.append(fresh)
        }

        endedIDs = endedIDs.filter { now.timeIntervalSince($0.value) < Self.endedTombstoneTTL }
        let known = Set(sessions.map(\.id))
        for fresh in scanned where !known.contains(fresh.id) && endedIDs[fresh.id] == nil {
            merged.append(fresh)
        }

        merged.sort(by: Self.displayOrder)
        // The poll runs every few seconds and almost always finds the same files;
        // publishing an identical array would redraw the popover for nothing.
        guard merged != sessions else { return }
        sessions = merged
    }

    /// Drops sessions that have gone quiet for `staleAfter` and whose host process is
    /// no longer running. A session whose terminal is still open is kept however quiet
    /// it is — the user can see it and would not expect it to vanish.
    func pruneStale(now: Date = Date()) {
        var kept: [AgentSession] = []
        var dropped: [AgentSession] = []
        for session in sessions {
            if Self.isStale(session, now: now) {
                dropped.append(session)
            } else {
                kept.append(session)
            }
        }
        guard !dropped.isEmpty else { return }
        sessions = kept
        for session in dropped {
            archive(session, endedAt: session.lastEventAt)
        }
    }

    private func upgradedIfCodexIsWorking(
        _ session: AgentSession, _ scanned: AgentSession?, now: Date
    ) -> AgentSession {
        guard session.source == .codex,
              let scanned, scanned.state == .working,
              session.state == .done || session.state == .idle
        else { return session }
        var upgraded = session
        upgraded.state = .working
        upgraded.stateSince = now
        upgraded.lastEventAt = max(session.lastEventAt, scanned.lastEventAt)
        return upgraded
    }

    private static func isStale(_ session: AgentSession, now: Date) -> Bool {
        guard now.timeIntervalSince(session.lastEventAt) >= staleAfter else { return false }
        guard let pid = session.host.pid else { return true }
        return !isProcessAlive(pid)
    }

    /// `kill(pid, 0)` sends no signal and only reports whether the process exists.
    /// `EPERM` means it exists but belongs to someone else — still alive.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
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

    /// `PostToolUse` for the two tools that *are* a question: `AskUserQuestion` and
    /// `ExitPlanMode` fire it once the user has answered in the terminal.
    private static func clearsAttention(_ toolName: String?) -> Bool {
        toolName == "AskUserQuestion" || toolName == "ExitPlanMode"
    }

    /// `activity` and `activityDetail` move as a pair, or not at all: a headline from
    /// one tool over the detail of another would expand into a lie. `PostToolUse`
    /// usually carries no summary, and then the one from `PreToolUse` stays up.
    private static func applyActivity(_ event: AgentEvent, to session: inout AgentSession) {
        guard let summary = event.toolSummary else { return }
        session.activity = summary
        session.activityDetail = event.toolDetail
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
    private static func displayOrder(_ a: AgentSession, _ b: AgentSession) -> Bool {
        if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
        if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
        return a.id < b.id
    }

    private func sortSessions() {
        sessions.sort(by: Self.displayOrder)
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
