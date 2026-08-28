import Foundation
import SwiftUI

enum TimeRange: String, CaseIterable, Identifiable {
    case fiveHours = "5h"
    case oneDay = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case ninetyDays = "90d"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .fiveHours: return 5 * 3600
        case .oneDay: return 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        case .thirtyDays: return 30 * 24 * 3600
        case .ninetyDays: return 90 * 24 * 3600
        }
    }
}

/// What the dashboard's cost sections can say about one provider.
///
/// Costs come from local CLI logs, never from the usage APIs, so "no costs here" is a
/// different fact for every provider — one has no log at all, one logs only totals, one
/// isn't parsed yet. The empty states quote `reason` verbatim rather than telling every
/// non-Claude user to switch to Claude.
enum CostSource: Equatable, Sendable {
    /// A per-turn local log: full daily / project / model breakdown.
    /// `shortName` titles the cost sections; `longName` completes a sentence
    /// ("built from …").
    case log(shortName: String, longName: String)
    /// No per-turn local data, and why.
    case unavailable(reason: String)

    var hasBreakdown: Bool {
        if case .log = self { return true }
        return false
    }

    var shortName: String? {
        if case let .log(shortName, _) = self { return shortName }
        return nil
    }

    var longName: String? {
        if case let .log(_, longName) = self { return longName }
        return nil
    }

    var reason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

@MainActor
final class DashboardState: ObservableObject {
    static let shared = DashboardState()

    @Published var range: TimeRange = .sevenDays
    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var cliBreakdown: CLIBreakdown?
    /// Burn rate for the selected provider's leading window.
    @Published private(set) var sessionBurn: BurnRatePrediction?
    /// Which bucket `sessionBurn` is about — providers name their session window
    /// differently ("five_hour", "codex_session", "gemini_pro").
    @Published private(set) var burnBucket: UsageBucket?
    /// What ran during the session window that's open right now.
    @Published private(set) var sessionWindow: WindowUsage?
    @Published private(set) var isLoadingCLI = false
    @Published private(set) var isLoadingHistory = false
    /// Providers that have recorded history — the picker's options.
    @Published private(set) var availableServices: [String] = []

    @AppStorage("dashboardSelectedService") private var storedService: String = "claude"

    /// The provider every chart on the dashboard is about. Published by hand:
    /// `@AppStorage` persists the value but never notifies from an
    /// ObservableObject, so the views would keep the old provider's data.
    var selectedService: String {
        get { storedService }
        set {
            guard newValue != storedService else { return }
            objectWillChange.send()
            storedService = newValue
            refreshAll()
        }
    }

    /// Where the selected provider's dollars come from — or why there are none.
    var costSource: CostSource { Self.costSource(for: selectedService) }

    /// Every provider either writes a local per-turn cost log or has a specific reason
    /// it can't be costed. Lumping them all under "Claude only" was both wrong (the Grok
    /// CLI does log dollars) and unhelpful (Antigravity never will).
    nonisolated static func costSource(for serviceID: String) -> CostSource {
        switch serviceID {
        case "claude":
            return .log(shortName: "Claude Code CLI", longName: "Claude Code's session logs")
        case "grok":
            return .log(shortName: "Grok CLI", longName: "the Grok CLI's session logs")
        case "codex":
            return .unavailable(reason: "The Codex CLI's logs only give running totals here — today's and the last 7 days' spend show in the menu bar popover. A day-by-day breakdown isn't wired up yet.")
        case "antigravity":
            return .unavailable(reason: "Antigravity doesn't keep a local token log, so costs can't be computed. Quota windows are on the Overview tab.")
        case "gemini":
            return .unavailable(reason: "Cost accounting for the Gemini CLI isn't supported yet. Quota windows are on the Overview tab.")
        default:
            return .unavailable(reason: "This provider keeps no local cost log, so costs can't be computed. Quota windows are on the Overview tab.")
        }
    }

    /// The aggregator behind `costSource`. nil exactly when there's no local log.
    nonisolated static func costAggregator(for serviceID: String) -> (any CostLogAggregating)? {
        switch serviceID {
        case "claude": return JSONLAggregator.shared
        case "grok": return GrokUsageAggregator.shared
        default: return nil
        }
    }

    private var refreshTask: Task<Void, Never>?

    private init() {}

    /// The provider's own display name while it's reporting; otherwise the id,
    /// which still reads ("codex" → "Codex").
    func displayName(for serviceID: String) -> String {
        AppState.shared.snapshot.services.first(where: { $0.id == serviceID })?.displayName
            ?? serviceID.capitalized
    }

    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshHistory()
            await self.refreshCLI()
            await self.refreshDerived()
        }
    }

    func refreshHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        availableServices = await HistoryStore.shared.recordedServices()
        // A provider that was removed (or never recorded on this machine) would
        // otherwise strand the dashboard on a permanently empty selection.
        if !availableServices.isEmpty, !availableServices.contains(storedService) {
            storedService = availableServices[0]
        }
        history = await HistoryStore.shared.all(service: storedService)
    }

    func refreshCLI() async {
        isLoadingCLI = true
        defer { isLoadingCLI = false }
        // A provider with no local log has no breakdown to show — clearing it stops the
        // previously selected provider's dollars from lingering under the new tab.
        guard let aggregator = Self.costAggregator(for: selectedService) else {
            cliBreakdown = nil
            return
        }
        await aggregator.refresh()
        cliBreakdown = await aggregator.breakdown()
    }

    func refreshDerived() async {
        // Burn rate needs only the last half hour of history — fetching that
        // slice directly keeps the per-poll path from copying the whole array
        // onto the main actor (and re-publishing it) every minute.
        let cutoff = Date().addingTimeInterval(-31 * 60)
        let service = selectedService
        let bucket = Self.burnBucket(of: service)
        burnBucket = bucket
        if let bucket {
            let recent = await HistoryStore.shared.records(since: cutoff, service: service)
            sessionBurn = Analytics.burnRate(records: recent, bucketId: bucket.id)
        } else {
            sessionBurn = nil
        }
        await refreshSessionWindow()
    }

    /// The window worth predicting: the session one when the provider has it,
    /// otherwise whichever non-promo window is furthest along — Gemini expresses
    /// every limit as a daily per-model quota and has no session window at all.
    private static func burnBucket(of serviceID: String) -> UsageBucket? {
        guard let service = AppState.shared.snapshot.services.first(where: { $0.id == serviceID })
        else { return nil }
        if let session = service.buckets.first(where: { $0.kind == .session && !$0.isPromotional }) {
            return session
        }
        return service.buckets
            .filter { !$0.isPromotional }
            .max(by: { $0.clampedPercent < $1.clampedPercent })
    }

    /// Bounds the selected provider's open session window from its own reset time and
    /// asks that provider's cost log what ran inside it. Nothing to show before the
    /// first poll, on a plan whose session window the API doesn't report, for a provider
    /// with no local cost log, or for one with no session window at all — Grok reports a
    /// billing-period bucket and nothing shorter, and inventing a window for it would be
    /// worse than showing none.
    func refreshSessionWindow() async {
        let service = selectedService
        guard let aggregator = Self.costAggregator(for: service),
              let session = AppState.shared.snapshot.services
            .first(where: { $0.id == service })?
            .buckets.first(where: { $0.kind == .session }),
            session.resetsAt < .distantFuture,
            let duration = session.windowDuration
        else {
            sessionWindow = nil
            return
        }
        let end = Date()
        let start = session.resetsAt.addingTimeInterval(-duration)
        guard start < end else {
            sessionWindow = nil
            return
        }
        sessionWindow = await aggregator.usage(from: start, to: end)
    }
}
