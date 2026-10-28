import Foundation
import WidgetKit

/// Bridges `ServiceSnapshot`s from the main app into the App Group shared file
/// and tells WidgetKit to refresh its timelines.
@MainActor
enum WidgetBridge {
    /// What the change comparison looks at: the rows, and how many providers the app polls.
    /// Not the time, which moves with every poll. The count is in it because two empty
    /// files can say different things — every enabled provider signed out, or every
    /// provider switched off (spec 2026-10-25 § Package 1) — and a widget told the first
    /// has to hear the second. The ids are in it because swapping which provider is on,
    /// with nothing reporting, keeps the count — and a provider widget has to hear that too.
    struct Publication: Equatable, Sendable {
        let services: [WidgetService]
        let enabledProviders: Int?
        var enabledProviderIDs: [String]? = nil
    }

    /// What this launch last wrote. nil until the first write, so a launch that has nothing
    /// to draw still replaces whatever an earlier run left in the file.
    private static var lastPublished: Publication?

    /// Called after every poll, on a display-mode change and from "Forget last known
    /// numbers". An empty list is written too: a widget never told "nothing to show"
    /// keeps the last numbers it was given for good. `polled` is `AppState.polledIDs`,
    /// nil before the first poll has started.
    static func publish(
        _ services: [ServiceSnapshot], at date: Date, mode: PercentDisplay.Mode, polled: Set<String>?
    ) {
        let snapshot = snapshot(from: services, at: date, mode: mode, polled: polled)
        let publication = publication(of: snapshot)
        guard shouldPublish(publication, lastPublished: lastPublished) else { return }
        let wrote = SharedWidgetStore.write(snapshot)
        lastPublished = recordedPublication(publication, wrote: wrote, previous: lastPublished)
        if wrote { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// What `lastPublished` becomes after a write. A write that failed (the container
    /// briefly unwritable) records nothing, so the one empty publication the rule below
    /// allows is tried again next time instead of being counted as delivered.
    nonisolated static func recordedPublication(
        _ publication: Publication, wrote: Bool, previous: Publication?
    ) -> Publication? {
        wrote ? publication : previous
    }

    /// Whether a publication reaches the file. Anything to draw goes every time, so the
    /// widget's "Updated …" moves with the polls. Nothing to draw goes once: when it
    /// becomes nothing, or when the providers that are on change (their count or which ones)
    /// — every minute would reload the widget's timelines to say the same nothing again.
    nonisolated static func shouldPublish(_ publication: Publication, lastPublished: Publication?) -> Bool {
        !publication.services.isEmpty || publication != lastPublished
    }

    /// The file `publish` writes for one poll: how many providers are on and which, sorted,
    /// both from the one set the poll ran with.
    nonisolated static func snapshot(
        from services: [ServiceSnapshot], at date: Date, mode: PercentDisplay.Mode, polled: Set<String>?
    ) -> WidgetSnapshot {
        snapshot(
            from: services, at: date, mode: mode,
            enabledProviders: polled?.count, enabledProviderIDs: polled.map { $0.sorted() }
        )
    }

    /// What the change comparison sees of a file.
    nonisolated static func publication(of snapshot: WidgetSnapshot) -> Publication {
        Publication(
            services: snapshot.services,
            enabledProviders: snapshot.enabledProviders,
            enabledProviderIDs: snapshot.enabledProviderIDs
        )
    }

    /// The whole file as a value. `publish` writes into the App Group container,
    /// which only the real app can reach, so everything it decides is decided here.
    nonisolated static func snapshot(
        from services: [ServiceSnapshot], at date: Date, mode: PercentDisplay.Mode,
        enabledProviders: Int? = nil, enabledProviderIDs: [String]? = nil
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            services: widgetServices(from: services),
            updatedAt: date,
            showsRemaining: mode == .remaining,
            enabledProviders: enabledProviders,
            enabledProviderIDs: enabledProviderIDs
        )
    }

    /// The mapping on its own: `publish` writes into the App Group container, which
    /// only the real app can reach, so the shape of what it writes is tested here.
    nonisolated static func widgetServices(from services: [ServiceSnapshot]) -> [WidgetService] {
        services
            .map { service in
                // A credit pool's figure is dollars and the widget has no dollar row: as a
                // percent it took the medium widget's second line from the weekly.
                var buckets = service.percentWindows.map { bucket in
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
