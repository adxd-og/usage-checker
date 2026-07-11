import Foundation
import UserNotifications

@MainActor
final class UsageNotifier {
    static let shared = UsageNotifier()

    private var lastFiredKey: [String: Int] = [:]
    private var didRequestAuth = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(snapshot: UsageSnapshot) {
        let now = Date()
        let inQuiet = isInQuietHours(at: now)

        // Threshold notifications
        if SettingsStore.shared.notificationsEnabled && !inQuiet {
            let thresholdHigh = SettingsStore.shared.threshold95
            let thresholdMid = SettingsStore.shared.threshold80

            for service in snapshot.services {
                // Promo pools don't alert (running a free bonus dry costs nothing);
                // the Enterprise spend limit alerts like any rate window.
                var watchable = service.buckets.filter { !$0.isPromotional }
                if let extra = service.extraUsage, extra.isEnabled {
                    watchable.append(UsageBucket(
                        id: "extra_usage",
                        label: extraUsageTitle(plan: service.plan),
                        utilization: extra.utilization,
                        resetsAt: .distantFuture,
                        kind: .other
                    ))
                }
                for bucket in watchable {
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
                        lastFiredKey[key] = bucketLevel
                    } else if bucketLevel == 0 {
                        lastFiredKey[key] = 0
                    }
                }
            }
        }

        // Daily summary
        checkDailySummary(at: now, inQuiet: inQuiet)
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
