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
    /// A permission banner is filed under the *request*, not the session: the app
    /// answers one request id at most once, and a second request from the same
    /// session is a different question that must not quietly replace the first.
    static let permissionPrefix = "agent-permission-"
    /// Tighter than `maxBodyLength`: a held request may show the tool name and a
    /// truncated summary and nothing else (design doc, security rule 6).
    static let maxPermissionBodyLength = 80

    /// "Needs you" is the alert the feature exists for, so it gets the one
    /// quiet-hours escape hatch in the app (`agentsNeedsYouBypassQuietHours`,
    /// default on): an agent that blocks at 23:30 blocks until morning otherwise.
    ///
    /// `permissionPending` is the phase-4 veto. When a request for that session is
    /// held, the `AGENT_PERMISSION` banner is already on screen asking the same
    /// question with Allow and Deny on it; a second banner that says the same thing
    /// and can do nothing about it is noise, and its withdrawal races the first.
    static func shouldNotifyNeedsYou(
        notifyEnabled: Bool,
        bypassQuietHours: Bool,
        isQuietHours: Bool,
        permissionPending: Bool
    ) -> Bool {
        guard notifyEnabled, !permissionPending else { return false }
        return !isQuietHours || bypassQuietHours
    }

    static func permissionIdentifier(requestID: String) -> String {
        permissionPrefix + requestID
    }

    /// The request id an identifier was built from, or nil when the banner is not a
    /// permission one. Kept apart from `sessionID(fromIdentifier:)` because the two
    /// answer different questions: this one says who to answer, that one where to jump.
    static func requestID(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(permissionPrefix) else { return nil }
        let id = String(identifier.dropFirst(permissionPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// "Usage tracker wants to run Bash". The tool name is the one part of the
    /// payload worth a title; without it the sentence still has to hold together.
    static func permissionTitle(projectName: String, toolName: String?) -> String {
        let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(projectName) wants to run \(tool.isEmpty ? "a tool" : tool)"
    }

    /// The truncated tool summary — "Bash: rm -rf build/DerivedData". A request that
    /// carries no summary still has to say what the buttons are for.
    static func permissionBody(toolSummary: String?) -> String {
        let summary = toolSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else { return "Waiting for your approval." }
        return truncate(summary, limit: maxPermissionBodyLength)
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
