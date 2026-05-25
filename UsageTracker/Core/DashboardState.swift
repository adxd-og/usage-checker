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

@MainActor
final class DashboardState: ObservableObject {
    static let shared = DashboardState()

    @Published var range: TimeRange = .sevenDays
    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var cliBreakdown: CLIBreakdown?
    @Published private(set) var burnFiveHour: BurnRatePrediction?
    @Published private(set) var isLoadingCLI = false
    @Published private(set) var isLoadingHistory = false

    private var refreshTask: Task<Void, Never>?

    private init() {}

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
        history = await HistoryStore.shared.all()
    }

    func refreshCLI() async {
        isLoadingCLI = true
        defer { isLoadingCLI = false }
        await JSONLAggregator.shared.refresh()
        cliBreakdown = await JSONLAggregator.shared.breakdown()
    }

    func refreshDerived() async {
        let records = history
        burnFiveHour = Analytics.burnRate(records: records, bucketId: "five_hour")
    }
}
