import Combine
import Foundation
import UserNotifications

/// `NSObject` only because `UNUserNotificationCenterDelegate` refines
/// `NSObjectProtocol`: the agent banners need a delegate to route their **Open**
/// action, and the notification centre will only talk to an Objective-C object.
@MainActor
final class UsageNotifier: NSObject {
    static let shared = UsageNotifier()

    /// Which threshold each bucket has already fired at, persisted so a restart
    /// (or an app update) doesn't replay every 80%/95% alert the user has seen.
    private var lastFiredKey: [String: Int]
    private var didRequestAuth = false

    /// Which window (keyed by its reset time) each time-based alert last fired for, so
    /// a 60-second poll doesn't repeat the same nudge — but a *new* window can nudge again.
    private var firedForWindow: [String: Double]

    /// Session ids that currently have a "needs you" banner on screen. Not
    /// persisted: a banner does not survive a relaunch, so neither should the
    /// record of it.
    private var notifiedNeedsYou: Set<String> = []
    private var agentSessionsObserver: AnyCancellable?

    /// The broker whose held requests this notifier banners. Injected in
    /// `startAgentNotifications` so a caller can hand in another one; `.shared`
    /// until then, because `agentNeedsYou` may be asked before launch finishes.
    private var broker: PermissionBroker = .shared

    static let firedLevelsKey = "notifierFiredLevels"
    static let firedWindowsKey = "notifierFiredWindows"
    /// How close to a reset counts as "about to start over".
    private static let resetLead: TimeInterval = 15 * 60
    /// How far a reading has to fall below the level it fired at before that level is
    /// armed again. See `thresholdOutcome`.
    nonisolated static let rearmMargin = 3
    /// Two reset times this close are the same window. The stamp is a double that
    /// round-trips through the preferences plist and comes from a server field that
    /// nothing stops from moving by a fraction of a second between polls; an exact
    /// inequality would replay the alert on every poll if it did.
    private static let windowMatchTolerance: TimeInterval = 2

    private override init() {
        lastFiredKey = UserDefaults.standard.dictionary(forKey: Self.firedLevelsKey) as? [String: Int] ?? [:]
        firedForWindow = UserDefaults.standard.dictionary(forKey: Self.firedWindowsKey) as? [String: Double] ?? [:]
        super.init()
    }

    private func rememberFired(_ level: Int, for key: String) {
        guard lastFiredKey[key] != level else { return }
        lastFiredKey[key] = level
        UserDefaults.standard.set(lastFiredKey, forKey: Self.firedLevelsKey)
    }

    /// Drops every "already fired" record. A settings reset should let the alerts speak
    /// again from the new thresholds rather than inherit the old ones' history.
    func forgetFiredState() {
        lastFiredKey = [:]
        firedForWindow = [:]
        UserDefaults.standard.removeObject(forKey: Self.firedLevelsKey)
        UserDefaults.standard.removeObject(forKey: Self.firedWindowsKey)
    }

    /// What a bucket's current reading does to its stored alert level.
    enum ThresholdOutcome: Equatable, Sendable {
        /// Crossed a level it hasn't fired at yet.
        case fire(level: Int)
        /// Fell far enough below the level it fired at to arm that level again.
        case rearm(level: Int)
        case unchanged
    }

    /// The threshold rule, with hysteresis, as a pure function — the notification centre
    /// is out of reach in tests, and this is the part worth testing.
    ///
    /// A percentage that hovers on a threshold used to alert over and over: 80 fired,
    /// 79 cleared the stored level outright, 80 fired again, every couple of minutes.
    /// Clearing now needs a real retreat — `rearmMargin` points below the level that
    /// fired — and it drops to whichever level the reading still clears, so a fall from
    /// 96% to 90% re-arms the 95% alert without replaying the 80% one.
    nonisolated static func thresholdOutcome(
        percent: Int,
        lastFired: Int,
        mid: Int,
        high: Int,
        rearmMargin: Int = UsageNotifier.rearmMargin
    ) -> ThresholdOutcome {
        let level = percent >= high ? high : (percent >= mid ? mid : 0)
        if level > lastFired { return .fire(level: level) }
        if lastFired > 0, percent < lastFired - rearmMargin { return .rearm(level: level) }
        return .unchanged
    }

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(snapshot: UsageSnapshot) async {
        let now = Date()
        let inQuiet = isInQuietHours(at: now)

        // Threshold notifications
        if SettingsStore.shared.notificationsEnabled && !inQuiet {
            let thresholdHigh = SettingsStore.shared.threshold95
            let thresholdMid = SettingsStore.shared.threshold80

            for service in snapshot.services {
                for bucket in Self.watchableBuckets(for: service) {
                    let key = "\(service.id):\(bucket.id)"
                    let p = Int(bucket.clampedPercent.rounded())

                    switch Self.thresholdOutcome(
                        percent: p,
                        lastFired: lastFiredKey[key] ?? 0,
                        mid: thresholdMid,
                        high: thresholdHigh
                    ) {
                    case .fire(let level):
                        let critical = level >= thresholdHigh
                        let resetPhrase = bucket.resetsAt < .distantFuture
                            ? " Resets \(formatReset(bucket.resetsAt))."
                            : ""
                        fire(
                            title: "\(service.displayName) — \(bucket.label) at \(level)%+",
                            body: "Currently \(p)%.\(resetPhrase)",
                            critical: critical
                        )
                        rememberFired(level, for: key)
                    case .rearm(let level):
                        rememberFired(level, for: key)
                    case .unchanged:
                        break
                    }
                }
            }
        }

        await evaluatePacing(snapshot: snapshot, now: now, inQuiet: inQuiet)

        // Daily summary
        checkDailySummary(at: now, inQuiet: inQuiet)
    }

    /// Which of a service's windows a threshold alert may fire for.
    ///
    /// Promo pools don't alert — running a free bonus dry costs nothing — and
    /// model-scoped caps ("Fable only") don't page the user either, because the
    /// all-models weekly is "the" limit. Unless scoping is all a provider has:
    /// Gemini's Pro/Flash daily quotas ARE its limits, so they alert, the same
    /// fallback `headlinePercent` makes. An Enterprise spend limit is a real
    /// limit and joins the list.
    ///
    /// Pure and static so the rule can be tested without the notification centre.
    nonisolated static func watchableBuckets(for service: ServiceSnapshot) -> [UsageBucket] {
        var watchable = service.buckets.filter { !$0.isPromotional && $0.kind != .modelSpecific }
        if watchable.isEmpty {
            watchable = service.buckets.filter { !$0.isPromotional }
        }
        if let extra = service.extraUsage, extra.isEnabled {
            watchable.append(UsageBucket(
                id: "extra_usage",
                label: extraUsageTitle(plan: service.plan),
                utilization: extra.utilization,
                resetsAt: .distantFuture,
                kind: .other
            ))
        }
        return watchable
    }

    // MARK: - Pace and reset

    /// Two nudges a percentage can't express: "at this pace the window runs out before it
    /// resets" and "the window you're squeezed against is about to start over".
    ///
    /// Only session windows qualify. A weekly cap resets on a horizon nobody can act on,
    /// and burn rate over a week is dominated by whether you worked yesterday.
    private func evaluatePacing(snapshot: UsageSnapshot, now: Date, inQuiet: Bool) async {
        guard !inQuiet, SettingsStore.shared.notificationsEnabled else { return }
        let wantsPace = SettingsStore.shared.paceAlertsEnabled
        let wantsReset = SettingsStore.shared.resetAlertsEnabled
        guard wantsPace || wantsReset else { return }

        let lead = TimeInterval(max(5, SettingsStore.shared.paceAlertLeadMinutes) * 60)
        let highWaterMark = Double(SettingsStore.shared.threshold80)
        // Fetched lazily and at most once per provider: most polls have no session
        // window worth predicting, and history is per service now.
        var recent: [String: [HistoryRecord]] = [:]

        for service in snapshot.services {
            for bucket in service.buckets where bucket.kind == .session && !bucket.isPromotional {
                guard bucket.resetsAt < .distantFuture else { continue }
                let untilReset = bucket.resetsAt.timeIntervalSince(now)
                guard untilReset > 0 else { continue }
                let percent = bucket.clampedPercent
                let key = "\(service.id):\(bucket.id)"

                var prediction: BurnRatePrediction?
                if wantsPace, percent < 100 {
                    if recent[service.id] == nil {
                        // Same slice the dashboard's burn rate uses.
                        recent[service.id] = await HistoryStore.shared.records(
                            since: now.addingTimeInterval(-31 * 60),
                            service: service.id
                        )
                    }
                    prediction = Analytics.burnRate(records: recent[service.id] ?? [], bucketId: bucket.id)
                }

                switch Analytics.pacingAdvice(
                    percent: percent,
                    untilReset: untilReset,
                    prediction: prediction,
                    leadSeconds: lead,
                    resetLeadSeconds: Self.resetLead,
                    highWaterMark: highWaterMark,
                    wantsPace: wantsPace,
                    wantsReset: wantsReset
                ) {
                case .aboutToReset:
                    fireOncePerWindow(
                        key: "reset:\(key)",
                        window: bucket.resetsAt,
                        title: "\(service.displayName) — \(bucket.label) resets in \(duration(untilReset))",
                        body: "Currently \(Int(percent.rounded()))%. It's about to start over."
                    )
                case .burningFast(let secondsToLimit):
                    fireOncePerWindow(
                        key: "pace:\(key)",
                        window: bucket.resetsAt,
                        title: "\(service.displayName) — \(bucket.label) burning fast",
                        body: "At this pace you'll hit 100% in about \(duration(secondsToLimit)), "
                            + "and it doesn't reset for another \(duration(untilReset)).",
                        critical: true
                    )
                case nil:
                    break
                }
            }
        }
    }

    /// Fires at most once for a given window, identified by its reset time.
    private func fireOncePerWindow(
        key: String,
        window: Date,
        title: String,
        body: String,
        critical: Bool = false
    ) {
        let stamp = window.timeIntervalSince1970
        if let fired = firedForWindow[key], abs(fired - stamp) < Self.windowMatchTolerance { return }
        firedForWindow[key] = stamp
        // Entries for windows long past are dead weight; drop them as we go.
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        firedForWindow = firedForWindow.filter { $0.value >= cutoff }
        UserDefaults.standard.set(firedForWindow, forKey: Self.firedWindowsKey)
        fire(title: title, body: body, critical: critical)
    }

    /// "35 min", "1h 20m" — the same shape as formatReset, without the "in".
    private func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: max(60, seconds)) ?? "a moment"
    }

    // MARK: - Quiet hours

    func isInQuietHours(at date: Date = Date()) -> Bool {
        guard SettingsStore.shared.quietHoursEnabled else { return false }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let start = SettingsStore.shared.quietHoursStart
        let end = SettingsStore.shared.quietHoursEnd
        if start == end { return false }
        if start < end {
            return hour >= start && hour < end
        } else {
            // Wraps over midnight: 23:00 → 9:00
            return hour >= start || hour < end
        }
    }

    // MARK: - Daily summary

    /// Local calendar day key, "2026-08-27".
    ///
    /// The stored key used to be `ISO8601DateFormatter().string(from: startOfDay)` — a
    /// GMT rendering of a *local* midnight, so the stored string moved with the machine's
    /// timezone and told you nothing about which local day it meant. Built per call
    /// rather than cached in a static so a timezone change takes effect immediately.
    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Whether a stored `lastDailySummaryDay` refers to `day`. Understands the current
    /// local key and the GMT ISO8601 timestamp older builds wrote, so upgrading doesn't
    /// send a second summary on the day it happens.
    nonisolated static func isSameDay(storedKey: String, as day: Date, calendar: Calendar = .current) -> Bool {
        guard !storedKey.isEmpty else { return false }
        if storedKey == dayKey(for: day, calendar: calendar) { return true }
        guard let legacy = ISO8601DateFormatter().date(from: storedKey) else { return false }
        return calendar.isDate(legacy, inSameDayAs: day)
    }

    private func checkDailySummary(at now: Date, inQuiet: Bool) {
        guard SettingsStore.shared.dailySummaryEnabled, !inQuiet else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard !Self.isSameDay(storedKey: SettingsStore.shared.lastDailySummaryDay, as: today, calendar: cal)
        else { return }
        let hour = cal.component(.hour, from: now)
        guard hour >= SettingsStore.shared.dailySummaryHour else { return }

        SettingsStore.shared.lastDailySummaryDay = Self.dayKey(for: today, calendar: cal)
        Task {
            await JSONLAggregator.shared.refresh()
            let breakdown = await JSONLAggregator.shared.breakdown()
            let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
            let yesterdaySummary = breakdown.daily.first(where: { cal.isDate($0.day, inSameDayAs: yesterday) })

            let body: String
            if let s = yesterdaySummary, s.totalCost > 0 {
                body = String(
                    format: "Yesterday: $%.2f across %d turns.",
                    s.totalCost, s.turns
                )
            } else {
                body = "No Claude Code activity yesterday."
            }
            await MainActor.run {
                self.fire(title: "Omelette — daily summary", body: body)
            }
        }
    }

    // MARK: - Agent sessions

    static let agentNeedsYouCategory = "AGENT_NEEDS_YOU"
    static let agentOpenAction = "AGENT_OPEN"
    static let agentHooksPromptCategory = "AGENT_HOOKS_PROMPT"
    static let agentHooksEnableAction = "AGENT_HOOKS_ENABLE"
    /// Fixed, because there is only ever one of these.
    static let agentHooksPromptIdentifier = "agent-hooks-prompt"
    static let agentPermissionCategory = "AGENT_PERMISSION"
    static let agentAllowAction = "AGENT_ALLOW"
    static let agentDenyAction = "AGENT_DENY"

    /// What a "needs you" banner says. A question or a plan is the same interruption
    /// as an approval with no buttons on it, so it gets the permission banner's
    /// shape — project and provider in the title, the verb in the subtitle — while a
    /// plain approval keeps the sentence it has always had. Pure, so the wording is
    /// tested rather than eyeballed in Notification Centre.
    nonisolated static func needsYouBanner(
        for session: AgentSession
    ) -> (title: String, subtitle: String?, body: String) {
        guard let attention = session.attention else {
            return (AgentNotificationRules.title(for: session), nil, AgentNotificationRules.body(for: session))
        }
        return (
            AgentNotificationRules.attentionTitle(for: session),
            AgentNotificationRules.attentionSubtitle(attention),
            AgentNotificationRules.attentionBody(
                headline: session.activity, detail: session.activityDetail, attention: attention
            )
        )
    }

    /// Installs the notification-centre delegate, registers the agent category and
    /// starts watching the session store. Called once at launch.
    ///
    /// The delegate comes before `requestAuthorizationIfNeeded()` in
    /// `applicationDidFinishLaunching` deliberately: a notification the user acts on
    /// must find a delegate already installed, including on the launch that tap
    /// causes.
    ///
    /// Three categories carry a button: "needs you" (**Open**), the one-time hooks
    /// prompt (**Enable**) and a held permission request (**Allow** / **Deny**).
    /// "Finished" needs none — its whole body is the action, and a click on the body
    /// arrives as `UNNotificationDefaultActionIdentifier`, which `handleAgentResponse`
    /// routes exactly like **Open**.
    func startAgentNotifications(
        store: AgentSessionStore = .shared,
        broker: PermissionBroker = .shared
    ) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Allow / Deny banners from a previous run have dead buttons: pending
        // requests live in memory only (design doc, rule 4), so nothing can answer
        // them any more. Sweep them before anything new is filed.
        center.getDeliveredNotifications { delivered in
            // Re-fetched inside: the centre object is not Sendable, and the
            // callback runs on the framework's own queue.
            let stale = delivered.map(\.request.identifier)
                .filter { $0.hasPrefix(AgentNotificationRules.permissionPrefix) }
            if !stale.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.agentNeedsYouCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.agentOpenAction,
                        title: "Open",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.agentHooksPromptCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.agentHooksEnableAction,
                        title: "Enable",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            ),
            // Neither action is `.foreground`. Omelette is an accessory app, so
            // activating it steals focus from the terminal the user is in — for a
            // button that exists to answer *without* going anywhere, that is the
            // wrong outcome, and the delegate receives the response perfectly well
            // in the background. Allow asks for an unlock first: the presence rule
            // holds requests while the screen is locked, and a lock screen must not
            // be a way to approve `rm -rf`.
            UNNotificationCategory(
                identifier: Self.agentPermissionCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.agentAllowAction,
                        title: "Allow",
                        options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: Self.agentDenyAction,
                        title: "Deny",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: [],
                options: []
            ),
        ])

        // `AgentSessionStore` and `UsageNotifier` are both `@MainActor`, and the store
        // documents these callbacks as delivered on main — so they are plain calls,
        // no `assumeIsolated` hop needed.
        store.onNeedsYou = { [weak self] session in
            self?.agentNeedsYou(session)
        }
        store.onDone = { [weak self] session in
            self?.agentDone(session)
        }
        // The store announces a session *entering* `needsYou`; nothing announces it
        // leaving, so the leaving edge is diffed out of the published list.
        agentSessionsObserver = store.$sessions.sink { [weak self] sessions in
            self?.clearResolvedNeedsYou(in: sessions)
        }

        // The broker is `@MainActor` like this object, so these are plain calls too.
        self.broker = broker
        broker.onPending = { [weak self] pending in
            self?.agentPermissionPending(pending)
        }
        broker.onResolved = { [weak self] pending, resolution in
            self?.permissionResolved(pending, resolution)
        }
    }

    /// The soft prompt's other half: one banner, once per install, for someone
    /// who has been running Claude Code without hooks and has no reason to know
    /// what they are missing. It never repeats — `agentsHooksPromptNotified` is
    /// set the moment it is scheduled — and it writes nothing by itself.
    ///
    /// Quiet hours skip it *without* burning the one shot: a prompt is not
    /// urgent, so it waits for a launch at a civilised hour instead.
    func promptForHooksIfNeeded() {
        guard !SettingsStore.shared.agentsHooksPromptNotified, !isInQuietHours() else { return }
        guard AgentHooksPrompt.shouldShow(
            claudePresent: AgentHooksPrompt.claudeIsPresent(),
            status: AgentHooksInstaller.claudeStatus(
                settingsURL: AgentPaths.claudeSettingsURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            ),
            dismissed: SettingsStore.shared.agentsHooksPromptDismissed
        ) else { return }

        SettingsStore.shared.agentsHooksPromptNotified = true
        fire(
            title: "See what your agents are doing",
            body: "Omelette can show which Claude Code session is working or waiting for you. "
                + "Enable adds hooks to ~/.claude/settings.json; reversible in Settings → Agents.",
            identifier: Self.agentHooksPromptIdentifier,
            category: Self.agentHooksPromptCategory
        )
    }

    /// **Enable** on that banner installs the hooks; a click on the body opens the
    /// popover, where the same offer is a row with a "Not now" next to it.
    private func handleHooksPromptResponse(action: String) {
        switch action {
        case Self.agentHooksEnableAction:
            do {
                try AgentHooksPrompt.installClaudeHooks()
            } catch {
                // `openSettings()` is a View's environment action and there is no
                // View here, so the tab request is parked for the next time
                // Settings opens — where the Agents tab shows what stopped it —
                // and the popover comes up with the offer still standing.
                SettingsRoute.shared.pendingTab = SettingsRoute.agentsTab
                NotificationCenter.default.post(name: .showPopover, object: nil)
            }
        case UNNotificationDefaultActionIdentifier:
            NotificationCenter.default.post(name: .showPopover, object: nil)
        default:
            break
        }
    }

    /// **Allow** and **Deny** answer the held request; anything else on that banner
    /// — a click on the body, "Close" — opens the popover, where the same two
    /// buttons sit on the row. A press that arrives after the hold window is a
    /// no-op: the broker has already released that id and forgotten it, and it
    /// answers each id at most once (design doc, rule 3).
    private func handlePermissionResponse(requestID: String, action: String) {
        switch action {
        case Self.agentAllowAction:
            broker.answer(id: requestID, .allow)
        case Self.agentDenyAction:
            broker.answer(id: requestID, .deny)
        case UNNotificationDefaultActionIdentifier:
            NotificationCenter.default.post(name: .showPopover, object: nil)
        default:
            break
        }
    }

    private func agentNeedsYou(_ session: AgentSession) {
        guard AgentNotificationRules.shouldNotifyNeedsYou(
            notifyEnabled: SettingsStore.shared.agentsNotifyNeedsYou,
            bypassQuietHours: SettingsStore.shared.agentsNeedsYouBypassQuietHours,
            isQuietHours: isInQuietHours(),
            permissionPending: broker.pending(for: session.id) != nil
        ) else { return }

        // Recorded only once the banner is actually scheduled: a suppressed alert
        // has nothing to withdraw later.
        notifiedNeedsYou.insert(session.id)
        let banner = Self.needsYouBanner(for: session)
        fire(
            title: banner.title,
            subtitle: banner.subtitle,
            body: banner.body,
            identifier: AgentNotificationRules.identifier(for: session),
            category: Self.agentNeedsYouCategory,
            timeSensitive: true
        )
    }

    /// A request the broker decided to hold. It follows the "needs you" toggle and
    /// its quiet-hours escape hatch, because it *is* that interruption — with two
    /// buttons on it. `permissionPending: false` is not a contradiction: the flag
    /// suppresses the *other* banner, and this is the one it suppresses it for.
    private func agentPermissionPending(_ pending: PendingPermission) {
        guard AgentNotificationRules.shouldNotifyNeedsYou(
            notifyEnabled: SettingsStore.shared.agentsNotifyNeedsYou,
            bypassQuietHours: SettingsStore.shared.agentsNeedsYouBypassQuietHours,
            isQuietHours: isInQuietHours(),
            permissionPending: false
        ) else { return }

        // Belt and braces against ordering: `AppState` registers with the broker
        // before the store applies the event, so `agentNeedsYou` already vetoed
        // itself — but a needs-you banner that slipped through would sit next to
        // this one asking the same question with no buttons. Pending *and*
        // delivered, because a request added a millisecond ago is still pending.
        let needsYouID = AgentNotificationRules.needsYouPrefix + pending.sessionID
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [needsYouID])
        center.removeDeliveredNotifications(withIdentifiers: [needsYouID])
        notifiedNeedsYou.remove(pending.sessionID)

        // The project name and the agent's name are the session's, not the payload's.
        // A request whose session we somehow do not know still has to name something,
        // and its id carries the source ("codex:<uuid>").
        let session = AgentSessionStore.shared.sessions.first { $0.id == pending.sessionID }
        let project = session?.projectName ?? "An agent"
        let source: AgentSource = session?.source
            ?? (pending.sessionID.hasPrefix("codex:") ? .codex : .claude)
        fire(
            title: AgentNotificationRules.permissionTitle(projectName: project, source: source),
            subtitle: AgentNotificationRules.permissionSubtitle(
                toolName: pending.toolName, attention: pending.attention
            ),
            body: AgentNotificationRules.permissionBody(headline: pending.toolSummary, detail: pending.detail),
            identifier: AgentNotificationRules.permissionIdentifier(requestID: pending.id),
            category: Self.agentPermissionCategory,
            timeSensitive: true
        )
    }

    /// Answered, expired, or released because you switched back to the terminal —
    /// either way the buttons are dead. A banner whose **Allow** no longer allows
    /// anything is worse than no banner (design doc, rule 5). An *expired* hold is
    /// the one case where nobody saw the two-minute banner: the terminal prompt is
    /// up now, so the plain needs-you banner (**Open**) takes its place — through
    /// `agentNeedsYou`, so `notifiedNeedsYou` and `clearResolvedNeedsYou` keep
    /// working. The broker has already dropped the id, so the veto inside it is off.
    private func permissionResolved(_ pending: PendingPermission, _ resolution: PermissionResolution) {
        // Pending *and* delivered: a request resolved milliseconds after `onPending`
        // (the helper was already gone) has a banner that is still in the queue.
        let identifier = AgentNotificationRules.permissionIdentifier(requestID: pending.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        guard resolution == .expired,
              let session = AgentSessionStore.shared.sessions.first(where: { $0.id == pending.sessionID }),
              session.state == .needsYou
        else { return }
        agentNeedsYou(session)
    }

    private func agentDone(_ session: AgentSession) {
        guard AgentNotificationRules.shouldNotifyDone(
            notifyEnabled: SettingsStore.shared.agentsNotifyDone,
            isQuietHours: isInQuietHours()
        ) else { return }
        fire(
            title: AgentNotificationRules.doneTitle(for: session),
            body: AgentNotificationRules.doneBody(for: session),
            identifier: AgentNotificationRules.doneIdentifier(for: session)
        )
    }

    /// Takes down banners for sessions that stopped waiting — you approved it in the
    /// terminal, or the session ended. Nothing else clears them: a notification with
    /// no identifier of ours is left alone.
    private func clearResolvedNeedsYou(in sessions: [AgentSession]) {
        let resolved = AgentNotificationRules.resolvedSessionIDs(
            notified: notifiedNeedsYou,
            sessions: sessions
        )
        guard !resolved.isEmpty else { return }
        notifiedNeedsYou.subtract(resolved)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: resolved.map { AgentNotificationRules.needsYouPrefix + $0 }
        )
    }

    /// Routes a tap on an agent notification to the session it names. A session that
    /// has since ended has nothing to jump to, so the popover — where the remaining
    /// sessions are — opens instead. The two banners that name no session are handled
    /// first: the hooks prompt, and a permission request (which names a request id).
    func handleAgentResponse(identifier: String, action: String) {
        if identifier == Self.agentHooksPromptIdentifier {
            handleHooksPromptResponse(action: action)
            return
        }
        if let requestID = AgentNotificationRules.requestID(fromIdentifier: identifier) {
            handlePermissionResponse(requestID: requestID, action: action)
            return
        }
        guard action == UNNotificationDefaultActionIdentifier || action == Self.agentOpenAction,
              let sessionID = AgentNotificationRules.sessionID(fromIdentifier: identifier)
        else { return }
        notifiedNeedsYou.remove(sessionID)
        if let session = AgentSessionStore.shared.sessions.first(where: { $0.id == sessionID }) {
            SessionActivator.jump(to: session)
        } else {
            NotificationCenter.default.post(name: .showPopover, object: nil)
        }
    }

    // MARK: - Plumbing

    /// The identifier defaults to a fresh UUID — a usage alert is a one-off. Agent
    /// alerts pass a stable one instead, which is what makes a repeat replace the
    /// banner and lets `clearResolvedNeedsYou` take it down again.
    private func fire(
        title: String,
        subtitle: String? = nil,
        body: String,
        critical: Bool = false,
        identifier: String? = nil,
        category: String? = nil,
        timeSensitive: Bool = false
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        if critical || timeSensitive {
            // Best effort: without the time-sensitive entitlement the system quietly
            // treats this as `.active`. The critical usage alerts already ask for it.
            content.interruptionLevel = .timeSensitive
        }
        if let category {
            content.categoryIdentifier = category
        }
        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func formatReset(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: delta).map { "in \($0)" } ?? "soon"
    }
}

extension UsageNotifier: UNUserNotificationCenterDelegate {
    /// Tapping the banner, or its **Open** action, jumps to the session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        // Only the two `String`s cross the isolation boundary. The completion handler
        // is an Objective-C block and is not `Sendable`, so it is called here instead
        // of being carried into the hop — the system only needs to know we took
        // delivery promptly, and the jump itself is fire-and-forget UI work.
        Task { @MainActor in
            self.handleAgentResponse(identifier: identifier, action: action)
        }
        completionHandler()
    }

    /// Omelette activates itself when you act on a notification (the **Open** action
    /// is `.foreground`), so without this the next banner would be swallowed as
    /// "the app is already frontmost" — which for an accessory app the user is not
    /// even looking at would simply lose the alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
