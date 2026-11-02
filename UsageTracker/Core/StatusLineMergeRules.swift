import Foundation

/// Claude's session and weekly windows from Claude Code's status line, where its reading
/// is newer than the OAuth one (spec 2026-11-02 Claude limits from the status line,
/// § Design › App, Merge).
///
/// Among the sessions dated within five minutes of now and run under the default Claude
/// folder (`~/.claude`; binding other accounts is cut from v1), the newest wins. Its
/// `five_hour` and `seven_day` replace the OAuth buckets of the same id only when it is
/// newer than Claude's `fetchedAt`; the bucket keeps OAuth's label, kind and length, and
/// only its percent, its reset, its source and its time (`asOf`, the session's) change.
/// With no OAuth bucket of that id — OAuth failing, or a last-known reading without it —
/// the window becomes a bucket under the label and kind OAuth gives it, whatever the
/// failed attempt's time. A window whose reset has passed is ignored. Everything else is
/// left as it was: the state and its chip, retention's dimming, `fetchedAt`, the
/// model-scoped windows, credit pools and extra usage that only OAuth reports, and every
/// other service.
enum StatusLineMergeRules {
    /// A reading dated further than this from now is not used.
    static let freshness: TimeInterval = 300

    /// One poll's merge. `applied` says the status line fed at least one window: what
    /// Claude's poll cadence keys on (spec § Cadence).
    struct Result: Equatable, Sendable {
        let snapshot: UsageSnapshot
        let applied: Bool
    }

    /// The Claude folder a reading must come from: `~/.claude`, spelled the way the CLI
    /// spells it (`StatusLineDrop.configDir`).
    static func defaultConfigDir(home: URL) -> String {
        StatusLineDrop.configDir(environment: [:], home: home)
    }

    /// The session whose numbers may stand in now: dated, from the default folder, within
    /// five minutes of now either way, the newest. A tie keeps the first.
    static func winner(
        _ sessions: [StatusLineFreshnessRules.Session], defaultConfigDir: String, now: Date
    ) -> StatusLineFreshnessRules.Session? {
        var best: (session: StatusLineFreshnessRules.Session, asOf: Date)?
        for session in sessions {
            guard let asOf = session.asOf,
                  session.configDir == defaultConfigDir,
                  abs(now.timeIntervalSince(asOf)) <= freshness
            else { continue }
            if let current = best, current.asOf >= asOf { continue }
            best = (session, asOf)
        }
        return best?.session
    }

    static func merge(
        _ snapshot: UsageSnapshot,
        sessions: [StatusLineFreshnessRules.Session],
        defaultConfigDir: String,
        now: Date
    ) -> Result {
        guard let index = snapshot.services.firstIndex(where: { $0.id == ClaudeOAuthProvider.serviceID }),
              let session = winner(sessions, defaultConfigDir: defaultConfigDir, now: now)
        else { return Result(snapshot: snapshot, applied: false) }
        let fed = feeding(snapshot.services[index], from: session, now: now)
        guard fed.applied else { return Result(snapshot: snapshot, applied: false) }
        var services = snapshot.services
        services[index] = fed.service
        return Result(
            snapshot: UsageSnapshot(
                services: services,
                fetchedAt: snapshot.fetchedAt,
                isStale: snapshot.isStale,
                lastError: snapshot.lastError
            ),
            applied: true
        )
    }

    /// One Claude service with `session`'s two windows in it, where they may go.
    static func feeding(
        _ claude: ServiceSnapshot, from session: StatusLineFreshnessRules.Session, now: Date
    ) -> (service: ServiceSnapshot, applied: Bool) {
        guard let asOf = session.asOf else { return (claude, false) }
        let newer = asOf > claude.fetchedAt
        var buckets = claude.buckets
        var applied = false
        let reported: [(id: String, window: StatusLineInput.RateLimits.Window?)] = [
            ("five_hour", session.fiveHour),
            ("seven_day", session.sevenDay),
        ]
        for entry in reported {
            guard let window = StatusLineFreshnessRules.liveWindow(entry.window, now: now) else { continue }
            if let at = buckets.firstIndex(where: { $0.id == entry.id }) {
                guard newer else { continue }
                let oauth = buckets[at]
                buckets[at] = UsageBucket(
                    id: oauth.id,
                    label: oauth.label,
                    utilization: window.usedPercent,
                    resetsAt: window.resetsAt,
                    kind: oauth.kind,
                    windowLength: oauth.windowLength,
                    credit: oauth.credit,
                    source: .statusLine,
                    asOf: asOf
                )
            } else if let standard = ClaudeOAuthProvider.knownWindow(id: entry.id) {
                // OAuth's order: the session window first, the weekly one after it.
                let position = entry.id == "five_hour" ? 0 : (buckets.first?.id == "five_hour" ? 1 : 0)
                buckets.insert(
                    UsageBucket(
                        id: entry.id,
                        label: standard.label,
                        utilization: window.usedPercent,
                        resetsAt: window.resetsAt,
                        kind: standard.kind,
                        source: .statusLine,
                        asOf: asOf
                    ),
                    at: position
                )
            } else {
                continue
            }
            applied = true
        }
        guard applied else { return (claude, false) }
        return (
            ServiceSnapshot(
                id: claude.id,
                displayName: claude.displayName,
                icon: claude.icon,
                plan: claude.plan,
                accountLabel: claude.accountLabel,
                buckets: buckets,
                extraUsage: claude.extraUsage,
                weekCost: claude.weekCost,
                state: claude.state,
                stateMessage: claude.stateMessage,
                fetchedAt: claude.fetchedAt,
                retryAfter: claude.retryAfter,
                isCarriedOver: claude.isCarriedOver,
                signedOutReason: claude.signedOutReason
            ),
            true
        )
    }
}
