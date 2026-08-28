import Foundation
import WidgetKit

/// Bridges `ServiceSnapshot`s from the main app into the App Group shared file
/// and tells WidgetKit to refresh its timelines.
@MainActor
enum WidgetBridge {
    static func publish(_ services: [ServiceSnapshot], at date: Date) {
        // Only services that actually have usage to show — a signed-out provider
        // would just clutter the widget.
        let widgetServices = services
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
                    spendLabel: spendLabel
                )
            }
            // A signed-out provider would just clutter the widget.
            .filter(\.hasContent)
        guard !widgetServices.isEmpty else { return }
        SharedWidgetStore.write(WidgetSnapshot(services: widgetServices, updatedAt: date))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
