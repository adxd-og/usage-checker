import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isLoading: Bool = false

    private let coordinator = ProviderCoordinator()
    private var inflight: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var lastRefreshAt: Date = .distantPast

    private init() {}

    func bootstrap() {
        refreshNow()
        startTimer()
    }

    func refreshNow() {
        if inflight != nil { return }
        let now = Date()
        if now.timeIntervalSince(lastRefreshAt) < 0.5 {
            return
        }
        lastRefreshAt = now
        inflight = Task { [weak self] in
            await self?.performRefresh()
            await MainActor.run { self?.inflight = nil }
        }
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        let admin = KeychainStore.loadAdminKey()
        let beta = SettingsStore.shared.anthropicBetaHeader
        let preferAdmin = SettingsStore.shared.preferAdminWhenAvailable
        let next = await coordinator.snapshot(
            adminKey: admin,
            betaHeader: beta,
            preferAdmin: preferAdmin
        )
        snapshot = next
        UsageNotifier.shared.evaluate(snapshot: next)
        if let claude = next.services.first(where: { $0.id == "claude" }), claude.state == .ok {
            await HistoryStore.shared.append(snapshot: claude)
            await DashboardState.shared.refreshHistory()
            await DashboardState.shared.refreshDerived()
            WidgetBridge.publish(claude)
        }
        NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
    }

    private func startTimer() {
        timer?.cancel()
        let queue = DispatchQueue(label: "com.usagetracker.timer")
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(15, SettingsStore.shared.refreshIntervalSeconds)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        t.resume()
        timer = t
    }

    func restartTimer() {
        startTimer()
    }
}
