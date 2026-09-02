import Foundation

/// Which agent events may page the user, what the banner is filed under, and what
/// it says.
///
/// Pure and static for the same reason as `UsageNotifier.thresholdOutcome` and
/// `watchableBuckets`: the notification centre is out of reach in tests, and the
/// rules are the part worth testing. Nothing here touches disk — an activity string
/// is hook payload and lives in memory only (spec, "Security and privacy").
enum AgentNotificationRules {
    /// One banner per session, filed under a stable name, so a second approval
    /// prompt for the same session replaces the first instead of stacking, and the
    /// app can withdraw it by name once the session stops waiting.
    static let needsYouPrefix = "agent-needsyou-"
    static let donePrefix = "agent-done-"
    /// A notification body is one line in Notification Centre. The system truncates
    /// past that anyway; our own ellipsis lands on a nicer boundary than theirs.
    static let maxBodyLength = 120

    /// "Needs you" is the alert the feature exists for, so it gets the one
    /// quiet-hours escape hatch in the app (`agentsNeedsYouBypassQuietHours`,
    /// default on): an agent that blocks at 23:30 blocks until morning otherwise.
    static func shouldNotifyNeedsYou(
        notifyEnabled: Bool,
        bypassQuietHours: Bool,
        isQuietHours: Bool
    ) -> Bool {
        guard notifyEnabled else { return false }
        return !isQuietHours || bypassQuietHours
    }

    /// "Finished" is opt-in and stays inside quiet hours like every usage alert.
    static func shouldNotifyDone(notifyEnabled: Bool, isQuietHours: Bool) -> Bool {
        notifyEnabled && !isQuietHours
    }

    static func identifier(for session: AgentSession) -> String {
        needsYouPrefix + session.id
    }

    static func doneIdentifier(for session: AgentSession) -> String {
        donePrefix + session.id
    }

    /// The session id an identifier was built from, or nil when the notification is
    /// not one of ours (threshold and summary alerts carry a UUID). Session ids
    /// contain a colon — `claude:abc-123` — so a known prefix is stripped rather
    /// than the string split on a separator.
    static func sessionID(fromIdentifier identifier: String) -> String? {
        for prefix in [needsYouPrefix, donePrefix] where identifier.hasPrefix(prefix) {
            let id = String(identifier.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    static func title(for session: AgentSession) -> String {
        "\(session.projectName) needs your approval"
    }

    static func doneTitle(for session: AgentSession) -> String {
        "\(session.projectName) finished"
    }

    /// The tool the session is blocked on — "Bash: xcodegen generate". A needsYou
    /// that arrived as a `Notification` hook rather than `PermissionRequest` has no
    /// tool input, hence the fallback sentence.
    static func body(for session: AgentSession) -> String {
        truncate(session.activity ?? "Waiting for your approval.")
    }

    /// What the turn did and how long it ran, in turns.
    static func doneBody(for session: AgentSession) -> String {
        let turns = session.turns == 1 ? "1 turn" : "\(session.turns) turns"
        guard let activity = session.activity else { return turns }
        return truncate("\(activity) · \(turns)")
    }

    static func truncate(_ text: String, limit: Int = maxBodyLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Sessions whose banner should come down: every id we banner-ed that is no
    /// longer waiting, whether because its state moved on or because the session is
    /// gone. Keyed by session id, not identifier, so the caller updates its own
    /// bookkeeping from the same answer.
    static func resolvedSessionIDs(
        notified: Set<String>,
        sessions: [AgentSession]
    ) -> Set<String> {
        let waiting = Set(sessions.filter { $0.state == .needsYou }.map(\.id))
        return notified.subtracting(waiting)
    }
}
