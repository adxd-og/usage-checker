import Foundation

private struct CostReportResponse: Decodable, Sendable {
    let data: [Bucket]
    struct Bucket: Decodable, Sendable {
        let results: [Result]
        struct Result: Decodable, Sendable {
            let amount: Amount?
            struct Amount: Decodable, Sendable {
                let value: String?
            }
        }
    }
}

final class AnthropicAdminProvider: UsageProvider, Sendable {
    let serviceID = "anthropic-admin"
    private let http: HTTPClient
    private let adminKey: String

    init(adminKey: String, http: HTTPClient = HTTPClient()) {
        self.http = http
        self.adminKey = adminKey
    }

    func fetch() async -> ServiceSnapshot {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let iso = ISO8601DateFormatter.usageTracker.string(from: weekAgo)

        let costURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(iso)")!
        let headers = [
            "x-api-key": adminKey,
            "anthropic-version": "2023-06-01",
            "Accept": "application/json",
        ]

        do {
            let cost = try await http.get(costURL, headers: headers, as: CostReportResponse.self, maxRetries: 2)
            var weekCost = 0.0
            for bucket in cost.data {
                for r in bucket.results {
                    if let s = r.amount?.value, let d = Double(s) {
                        weekCost += d
                    }
                }
            }

            return ServiceSnapshot(
                id: serviceID,
                displayName: "Anthropic Enterprise",
                icon: "building.2",
                plan: "Enterprise",
                accountLabel: nil,
                buckets: [],
                extraUsage: nil,
                weekCost: weekCost,
                state: .ok,
                stateMessage: nil,
                fetchedAt: now
            )
        } catch {
            return ServiceSnapshot(
                id: serviceID,
                displayName: "Anthropic Enterprise",
                icon: "building.2",
                plan: nil,
                accountLabel: nil,
                buckets: [],
                extraUsage: nil,
                weekCost: nil,
                state: .error,
                stateMessage: error.localizedDescription,
                fetchedAt: now
            )
        }
    }
}
