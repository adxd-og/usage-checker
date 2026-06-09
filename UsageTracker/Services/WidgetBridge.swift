import Foundation
import WidgetKit

/// Bridges `ServiceSnapshot` from the main app into the App Group shared file
/// and tells WidgetKit to refresh its timeline.
@MainActor
enum WidgetBridge {
    static func publish(_ snapshot: ServiceSnapshot) {
        let widget = WidgetSnapshot(
            fiveHourPercent: bucket(snapshot, "five_hour"),
            fiveHourResetsAt: bucketReset(snapshot, "five_hour"),
            sevenDayPercent: bucket(snapshot, "seven_day"),
            sevenDayResetsAt: bucketReset(snapshot, "seven_day"),
            modelBuckets: snapshot.buckets
                .filter { $0.kind == .modelSpecific }
                .map { WidgetBucket(id: $0.id, label: $0.label, percent: $0.utilization) },
            plan: snapshot.plan,
            updatedAt: snapshot.fetchedAt
        )
        SharedWidgetStore.write(widget)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func bucket(_ s: ServiceSnapshot, _ id: String) -> Double? {
        s.buckets.first(where: { $0.id == id })?.utilization
    }

    private static func bucketReset(_ s: ServiceSnapshot, _ id: String) -> Date? {
        let r = s.buckets.first(where: { $0.id == id })?.resetsAt
        if let r, r < Date.distantFuture { return r }
        return nil
    }
}
