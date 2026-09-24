import Foundation
import WidgetKit

/// Bridges `ServiceSnapshot`s from the main app into the App Group shared file
/// and tells WidgetKit to refresh its timelines.
@MainActor
enum WidgetBridge {
    /// The services this launch last wrote. nil until the first write, so a launch that
    /// has nothing to draw still replaces whatever an earlier run left in the file.
    private static var lastPublished: [WidgetService]?

    /// Called after every poll, on a display-mode change and from "Forget last known
    /// numbers". An empty list is written too: a widget never told "nothing to show"
    /// keeps the last numbers it was given for good.
    static func publish(_ services: [ServiceSnapshot], at date: Date, mode: PercentDisplay.Mode) {
        let snapshot = snapshot(from: services, at: date, mode: mode)
        guard shouldPublish(snapshot.services, lastPublished: lastPublished) else { return }
        SharedWidgetStore.write(snapshot)
        lastPublished = snapshot.services
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Whether a list reaches the file. Anything to draw goes every time, so the widget's
    /// "Updated …" moves with the polls. An empty list goes once, when it becomes empty —
    /// every minute would reload the widget's timelines to say nothing again.
    nonisolated static func shouldPublish(
        _ services: [WidgetService], lastPublished: [WidgetService]?
    ) -> Bool {
        !services.isEmpty || services != lastPublished
    }

    /// The whole file as a value. `publish` writes into the App Group container,
    /// which only the real app can reach, so everything it decides is decided here.
    nonisolated static func snapshot(
        from services: [ServiceSnapshot], at date: Date, mode: PercentDisplay.Mode
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            services: widgetServices(from: services),
            updatedAt: date,
            showsRemaining: mode == .remaining
        )
    }

    /// The mapping on its own: `publish` writes into the App Group container, which
    /// only the real app can reach, so the shape of what it writes is tested here.
    nonisolated static func widgetServices(from services: [ServiceSnapshot]) -> [WidgetService] {
        services
            .map { service in
                var buckets = service.buckets.map { bucket in
                    WidgetBucket(
                        id: bucket.id,
                        label: bucket.label,
                        percent: bucket.utilization,
                        resetsAt: bucket.resetsAt < .distantFuture ? bucket.resetsAt : nil,
                        kind: bucket.kind.rawValue
                    )
                }
                // A spend limit is a real limit — the popover and notifications both
                // treat it as one, so the widget shows it as a window too.
                if let extra = service.extraUsage, extra.isEnabled {
                    buckets.append(WidgetBucket(
                        id: "extra_usage",
                        label: extraUsageTitle(plan: service.plan),
                        percent: extra.utilization,
                        kind: BucketKind.other.rawValue
                    ))
                }
                // Windowless pay-as-you-go: local CLI spend is all there is to show.
                let spendLabel: String? = {
                    guard buckets.isEmpty, let cost = service.weekCost, cost > 0 else { return nil }
                    return String(format: "$%.2f last 7 days", cost)
                }()
                return WidgetService(
                    id: service.id,
                    name: service.displayName,
                    icon: service.icon,
                    plan: service.plan,
                    buckets: buckets,
                    spendLabel: spendLabel,
                    // Retained numbers go through unchanged; the flag is what lets the
                    // widget draw them as old rather than as current.
                    isRetained: service.isRetained
                )
            }
            // A signed-out provider would just clutter the widget.
            .filter(\.hasContent)
    }
}
