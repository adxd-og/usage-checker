import Foundation
import UserNotifications

@MainActor
final class UsageNotifier {
    static let shared = UsageNotifier()

    /// Which threshold each bucket has already fired at, persisted so a restart
    /// (or an app update) doesn't replay every 80%/95% alert the user has seen.
    private var lastFiredKey: [String: Int]
    private var didRequestAuth = false

    /// Which window (keyed by its reset time) each time-based alert last fired for, so
    /// a 60-second poll doesn't repeat the same nudge — but a *new* window can nudge again.
    private var firedForWindow: [String: Double]

    private static let firedLevelsKey = "notifierFiredLevels"
    private static let firedWindowsKey = "notifierFiredWindows"
    /// How close to a reset counts as "about to start over".
    private static let resetLead: TimeInterval = 15 * 60

    private init() {
        lastFiredKey = UserDefaults.standard.dictionary(forKey: Self.firedLevelsKey) as? [String: Int] ?? [:]
        firedForWindow = UserDefaults.standard.dictionary(forKey: Self.firedWindowsKey) as? [String: Double] ?? [:]
    }

    private func rememberFired(_ level: Int, for key: String) {
        guard lastFiredKey[key] != level else { return }
        lastFiredKey[key] = level
        UserDefaults.standard.set(lastFiredKey, forKey: Self.firedLevelsKey)
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
                    let bucketLevel: Int
                    if p >= thresholdHigh { bucketLevel = thresholdHigh }
                    else if p >= thresholdMid { bucketLevel = thresholdMid }
                    else { bucketLevel = 0 }

                    let prev = lastFiredKey[key] ?? 0
                    if bucketLevel > prev {
                        let critical = bucketLevel >= thresholdHigh
                        let resetPhrase = bucket.resetsAt < .distantFuture
                            ? " Resets \(formatReset(bucket.resetsAt))."
                            : ""
                        fire(
                            title: "\(service.displayName) — \(bucket.label) at \(bucketLevel)%+",
                            body: "Currently \(p)%.\(resetPhrase)",
                            critical: critical
                        )
                        rememberFired(bucketLevel, for: key)
                    } else if bucketLevel == 0 {
                        rememberFired(0, for: key)
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
        guard firedForWindow[key] != stamp else { return }
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

    private func checkDailySummary(at now: Date, inQuiet: Bool) {
        guard SettingsStore.shared.dailySummaryEnabled, !inQuiet else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let formatter = ISO8601DateFormatter()
        let todayKey = formatter.string(from: today)
        guard SettingsStore.shared.lastDailySummaryDay != todayKey else { return }
        let hour = cal.component(.hour, from: now)
        guard hour >= SettingsStore.shared.dailySummaryHour else { return }

        SettingsStore.shared.lastDailySummaryDay = todayKey
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

    // MARK: - Plumbing

    private func fire(title: String, body: String, critical: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        if critical {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
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
