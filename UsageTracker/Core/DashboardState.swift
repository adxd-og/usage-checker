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
    /// Burn rate for *every* provider that has one, keyed by service id. The popover's
    /// tab and the dashboard's picker are separate persisted choices, so a view that
    /// isn't following the picker has to be able to ask about its own provider instead
    /// of borrowing the selected one's verdict.
    @Published private(set) var burnByService: [String: BurnRatePrediction] = [:]
    /// Which bucket `sessionBurn` is about — providers name their session window
    /// differently ("five_hour", "codex_session", "gemini_pro").
    @Published private(set) var burnBucket: UsageBucket?
    /// What ran during the session window that's open right now.
    @Published private(set) var sessionWindow: WindowUsage?
    /// The selected provider's chartable quota windows, named from the live snapshot
    /// wherever it is still reporting them. Published next to `history` because the
    /// quota views need both at once: a record stores bucket ids and percentages, and
    /// a bucket id with no label is not chartable.
    @Published private(set) var quotaBuckets: [QuotaBucketInfo] = []
    @Published private(set) var isLoadingCLI = false
    @Published private(set) var isLoadingHistory = false
    /// The provider picker's options — see `availableServices(recorded:snapshot:disabled:)`.
    @Published private(set) var availableServices: [String] = []

    static let defaultService = "claude"
    static let selectionKey = "dashboardSelectedService"

    @AppStorage(DashboardState.selectionKey) private var storedService: String = DashboardState.defaultService

    /// Providers that have ever recorded a history point. Cached so the poll path can
    /// re-derive the picker's options without scanning the whole log every minute.
    private var recordedServices: [String] = []
    private var didLoadRecordedServices = false

    /// The provider every chart on the dashboard is about.
    var selectedService: String {
        get { storedService }
        set {
            guard newValue != storedService else { return }
            objectWillChange.send()
            storedService = newValue
            // Synchronously, before anything is awaited: a scan already in flight for
            // the old provider can still be inside `await aggregator.refresh()`, and
            // leaving its numbers on screen under the new tab is worse than a blank.
            clearProviderScopedState()
            refreshAll()
        }
    }

    /// Everything on screen that belongs to one provider and no other.
    private func clearProviderScopedState() {
        cliBreakdown = nil
        sessionWindow = nil
        sessionBurn = nil
        burnBucket = nil
        history = []
        quotaBuckets = []
    }

    /// Back to the default provider without kicking off a reload — the settings reset
    /// that calls this triggers a full refresh of its own straight after.
    func resetSelection() {
        guard storedService != Self.defaultService else { return }
        objectWillChange.send()
        storedService = Self.defaultService
        clearProviderScopedState()
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
            return .unavailable(reason: "Antigravity doesn't keep a local token log, so costs can't be computed. Quota over time is charted instead.")
        case "gemini":
            return .unavailable(reason: "Cost accounting for the Gemini CLI isn't supported yet. Quota over time is charted instead.")
        default:
            return .unavailable(reason: "This provider keeps no local cost log, so costs can't be computed. Quota over time is charted instead.")
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
    /// Bumped by every `refreshAll()`. `Task.cancel()` is cooperative and an actor call
    /// already in flight runs to completion regardless, so a pass identifies itself and
    /// checks it is still the current one before publishing anything.
    private var refreshGeneration = 0

    /// One refresh pass's claim on the published state.
    struct RefreshPass: Equatable, Sendable {
        let service: String
        let generation: Int
    }

    /// Whether a pass that started as `pass` may still publish.
    ///
    /// Both halves matter. The generation stops a superseded pass from overwriting a
    /// newer one's result (and from clearing a loading flag the newer pass still owns);
    /// the service stops a pass that was started for Claude — by the poll path, which
    /// has no generation of its own — from painting Claude's costs under the Grok tab.
    nonisolated static func canPublish(
        pass: RefreshPass,
        currentService: String,
        currentGeneration: Int
    ) -> Bool {
        pass.service == currentService && pass.generation == currentGeneration
    }

    private func begin() -> RefreshPass {
        RefreshPass(service: storedService, generation: refreshGeneration)
    }

    private func canPublish(_ pass: RefreshPass) -> Bool {
        !Task.isCancelled && Self.canPublish(
            pass: pass,
            currentService: storedService,
            currentGeneration: refreshGeneration
        )
    }

    private init() {}

    /// The provider's own display name while it's reporting; otherwise the id,
    /// which still reads ("codex" → "Codex").
    func displayName(for serviceID: String) -> String {
        AppState.shared.snapshot.services.first(where: { $0.id == serviceID })?.displayName
            ?? serviceID.capitalized
    }

    func refreshAll() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshHistory()
            await self.refreshCLI()
            await self.refreshDerived()
        }
    }

    func refreshHistory() async {
        let generation = refreshGeneration
        isLoadingHistory = true
        defer { if refreshGeneration == generation { isLoadingHistory = false } }

        recordedServices = await HistoryStore.shared.recordedServices()
        didLoadRecordedServices = true
        guard refreshGeneration == generation, !Task.isCancelled else { return }
        // Before the service is captured: the heal may change it, and the load below
        // has to be for whatever it settles on.
        healSelection()

        let pass = begin()
        let loaded = await HistoryStore.shared.all(service: pass.service)
        guard canPublish(pass) else { return }
        history = loaded
        // Same pass, same guard: the labels come from the live snapshot and the ids from
        // the records, so deriving them anywhere else would need a second refresh path
        // and could pair one provider's ids with another's names.
        quotaBuckets = QuotaAnalytics.bucketInfos(
            service: AppState.shared.snapshot.services.first(where: { $0.id == pass.service }),
            records: loaded
        )
    }

    /// The windows a quota chart may summarise for the selected provider — the core
    /// ones, in the provider's own order.
    var quotaCoreBucketIDs: [String] {
        quotaBuckets.filter(\.isCore).map(\.id)
    }

    func refreshCLI() async {
        let pass = begin()
        isLoadingCLI = true
        defer { if refreshGeneration == pass.generation { isLoadingCLI = false } }

        // A provider with no local log has no breakdown to show — clearing it stops the
        // previously selected provider's dollars from lingering under the new tab.
        guard let aggregator = Self.costAggregator(for: pass.service) else {
            if canPublish(pass) { cliBreakdown = nil }
            return
        }
        await aggregator.refresh()
        guard canPublish(pass) else { return }
        let breakdown = await aggregator.breakdown()
        guard canPublish(pass) else { return }
        cliBreakdown = breakdown
    }

    func refreshDerived() async {
        // Which providers have ever recorded used to be read only when the dashboard
        // window opened. Loading it once per launch here is what lets the heal below run
        // on the poll path — and, just as importantly, what stops it from mistaking a
        // provider's first failed poll for a provider that has nothing to show.
        if !didLoadRecordedServices {
            didLoadRecordedServices = true
            recordedServices = await HistoryStore.shared.recordedServices()
        }
        // The poll path calls this directly, so it is also where a stale selection gets
        // corrected on a machine whose dashboard is never opened.
        healSelection()
        let pass = begin()

        // Burn rate needs only the last half hour of history — fetching that
        // slice directly keeps the per-poll path from copying the whole array
        // onto the main actor (and re-publishing it) every minute. One call for
        // every provider rather than one per provider: the popover needs them all.
        let cutoff = Date().addingTimeInterval(-31 * 60)
        let recent = await HistoryStore.shared.recentByService(since: cutoff)
        guard canPublish(pass) else { return }

        var burns: [String: BurnRatePrediction] = [:]
        for service in AppState.shared.snapshot.services {
            guard let bucket = Self.burnBucket(of: service.id),
                  let burn = Analytics.burnRate(records: recent[service.id] ?? [], bucketId: bucket.id)
            else { continue }
            burns[service.id] = burn
        }
        burnByService = burns
        burnBucket = Self.burnBucket(of: pass.service)
        sessionBurn = burns[pass.service]

        await refreshSessionWindow()
    }

    /// The burn prediction for one provider, whoever is asking. nil when that provider
    /// has no window worth predicting or not enough history yet.
    func burn(for serviceID: String) -> BurnRatePrediction? {
        burnByService[serviceID]
    }

    /// The picker's options, and the answer to "is the stored selection still real?".
    ///
    /// History alone was not enough. It is written only for providers that have polled
    /// `.ok` at least once, so a Grok-only user — whose Claude never reports — kept the
    /// default "claude" selection, and the floating window and popover followed it into
    /// an empty tab. The live snapshot answers for a provider that is reporting right
    /// now; recorded history keeps a signed-out provider's past readable; and a provider
    /// switched off in Settings is not on offer at all.
    nonisolated static func availableServices(
        recorded: [String],
        snapshot: UsageSnapshot,
        disabled: Set<String>
    ) -> [String] {
        let live = snapshot.services
            .filter { !$0.buckets.isEmpty || $0.weekCost != nil }
            .map(\.id)
        var seen = Set<String>()
        return (live + recorded.sorted()).filter {
            !disabled.contains($0) && seen.insert($0).inserted
        }
    }

    /// The selection to use when the stored one is no longer on offer. Falls back to the
    /// stored value when there is nothing to heal to, so an empty first launch doesn't
    /// blank the picker.
    nonisolated static func healedSelection(stored: String, available: [String]) -> String {
        available.contains(stored) || available.isEmpty ? stored : available[0]
    }

    /// Providers switched off in Settings. Claude has no toggle — it is always polled.
    private static var disabledServices: Set<String> {
        let s = SettingsStore.shared
        var off: Set<String> = []
        if !s.codexProviderEnabled { off.insert("codex") }
        if !s.geminiProviderEnabled { off.insert("gemini") }
        if !s.antigravityProviderEnabled { off.insert("antigravity") }
        if !s.grokProviderEnabled { off.insert("grok") }
        return off
    }

    /// Rebuilds the picker's options and moves the selection onto one of them if it has
    /// fallen off. Cheap and synchronous, so the poll path can run it too — it used to
    /// happen only inside `refreshHistory()`, i.e. only while the dashboard was open.
    private func healSelection() {
        let options = Self.availableServices(
            recorded: recordedServices,
            snapshot: AppState.shared.snapshot,
            disabled: Self.disabledServices
        )
        if options != availableServices { availableServices = options }

        let healed = Self.healedSelection(stored: storedService, available: options)
        guard healed != storedService else { return }
        objectWillChange.send()
        storedService = healed
        clearProviderScopedState()
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
        let pass = begin()
        guard let aggregator = Self.costAggregator(for: pass.service),
              let session = AppState.shared.snapshot.services
            .first(where: { $0.id == pass.service })?
            .buckets.first(where: { $0.kind == .session }),
            session.resetsAt < .distantFuture,
            let duration = session.windowDuration
        else {
            if canPublish(pass) { sessionWindow = nil }
            return
        }
        let end = Date()
        let start = session.resetsAt.addingTimeInterval(-duration)
        guard start < end else {
            if canPublish(pass) { sessionWindow = nil }
            return
        }
        let usage = await aggregator.usage(from: start, to: end)
        guard canPublish(pass) else { return }
        sessionWindow = usage
    }
}
