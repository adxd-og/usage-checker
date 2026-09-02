import Foundation

/// Pure selection and formatting rules shared by the popover, tiles and menu bar.
/// Extracted from PopoverView so they can be unit-tested and reused by the
/// widget/floating window later.
enum WindowRanking {
    /// Sentinel for the "All providers" segment.
    static let allTab = "all"

    /// The most-constrained window of a service — the one that answers "can I
    /// keep working right now?". Promotional pools and model-scoped windows do
    /// not compete unless they are all the account has; enabled extra usage
    /// (spend limit) does compete. Ties resolve to the first in API order.
    static func heroBucket(for service: ServiceSnapshot) -> UsageBucket? {
        var candidates = coreCandidates(for: service)
        if candidates.isEmpty {
            candidates = service.buckets.filter { !$0.isPromotional }
        }
        if candidates.isEmpty {
            candidates = service.buckets
        }
        return worst(of: candidates)
    }

    /// Provider-tab hero: the session window when the service has one — it
    /// answers "can I keep working right now" and the tab has room to show every
    /// other window underneath — otherwise the most-constrained window.
    /// Tiles on the All tab keep `heroBucket`, where one ring is all there is.
    static func detailHero(for service: ServiceSnapshot) -> UsageBucket? {
        service.buckets.first { $0.kind == .session && !$0.isPromotional } ?? heroBucket(for: service)
    }

    /// The window shown under the hero on a tile: the all-models weekly when it
    /// is not already the hero, otherwise the next-worst core window. nil when
    /// the service has nothing else worth showing.
    static func secondaryBucket(for service: ServiceSnapshot) -> UsageBucket? {
        guard let hero = heroBucket(for: service) else { return nil }
        if hero.id != "seven_day", let weekly = service.buckets.first(where: { $0.id == "seven_day" }) {
            return weekly
        }
        let rest = coreCandidates(for: service).filter { $0.id != hero.id }
        return worst(of: rest)
    }

    /// Session windows to list under the hero on a provider tab: every
    /// `.session` bucket that is not the hero itself. Mid-week the weekly often
    /// wins the hero contest, and the 5-hour window is the number people check
    /// most — it must never vanish just because it is the calmer of the two.
    static func sessionRows(for service: ServiceSnapshot, hero: UsageBucket?) -> [UsageBucket] {
        service.buckets.filter { $0.kind == .session && $0.id != hero?.id }
    }

    /// "All models" → "All", "Opus only" → "Opus"; other labels untouched.
    static func shortWindowLabel(_ label: String) -> String {
        if label == "All models" { return "All" }
        if label.hasSuffix(" only") { return String(label.dropLast(" only".count)) }
        return label
    }

    /// Persisted tab self-heal: a stored id that is not on screen falls back to All.
    static func resolveTab(stored: String, displayed: [ServiceSnapshot]) -> String {
        if displayed.contains(where: { $0.id == stored }) { return stored }
        return allTab
    }

    /// "2h 15m left"; "resets now" once the reset time has passed; nil when unknown.
    static func remainingText(until resetsAt: Date, now: Date = Date()) -> String? {
        guard resetsAt < .distantFuture else { return nil }
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 { return "resets now" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        // The app's strings are English; pinning the locale keeps "2h 15m" stable
        // on non-English machines (and makes the unit test deterministic).
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        return f.string(from: delta).map { "\($0) left" }
    }

    // MARK: - Private

    private static func coreCandidates(for service: ServiceSnapshot) -> [UsageBucket] {
        var candidates = service.buckets.filter { !$0.isPromotional && $0.kind != .modelSpecific }
        if let extra = service.extraUsage, extra.isEnabled {
            candidates.append(UsageBucket(
                id: "\(service.id)_extra_usage",
                label: extraUsageTitle(plan: service.plan),
                utilization: extra.utilization,
                resetsAt: .distantFuture,
                kind: .other
            ))
        }
        return candidates
    }

    private static func worst(of buckets: [UsageBucket]) -> UsageBucket? {
        buckets.enumerated().max { a, b in
            if a.element.clampedPercent != b.element.clampedPercent {
                return a.element.clampedPercent < b.element.clampedPercent
            }
            return a.offset > b.offset
        }?.element
    }
}
