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
            .filter { !$0.buckets.isEmpty }
            .map { service in
                WidgetService(
                    id: service.id,
                    name: service.displayName,
                    icon: service.icon,
                    plan: service.plan,
                    buckets: service.buckets.map { bucket in
                        WidgetBucket(
                            id: bucket.id,
                            label: bucket.label,
                            percent: bucket.utilization,
                            resetsAt: bucket.resetsAt < .distantFuture ? bucket.resetsAt : nil,
                            kind: bucket.kind.rawValue
                        )
                    }
                )
            }
        guard !widgetServices.isEmpty else { return }
        SharedWidgetStore.write(WidgetSnapshot(services: widgetServices, updatedAt: date))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
