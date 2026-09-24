import Foundation

private struct CostReportResponse: Decodable, Sendable {
    let data: [Bucket]
    struct Bucket: Decodable, Sendable {
        let results: [Result]
        struct Result: Decodable, Sendable {
            /// Cents, as a decimal string: "12345.00" is $123.45. The API sends a
            /// string; a JSON number and the older `{"value": "…"}` object are read
            /// the same way. Missing or null is no amount. Any other shape fails the
            /// whole report, so a changed API reads "Decoding failed" on the row
            /// rather than a quiet $0.00.
            let amount: String?

            private enum CodingKeys: String, CodingKey { case amount }
            private struct Wrapped: Decodable { let value: String? }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? c.decodeIfPresent(String.self, forKey: .amount) {
                    amount = text
                } else if let number = try? c.decodeIfPresent(Decimal.self, forKey: .amount) {
                    amount = number.description
                } else {
                    amount = try c.decodeIfPresent(Wrapped.self, forKey: .amount)?.value
                }
            }
        }
    }
}

final class AnthropicAdminProvider: UsageProvider, Sendable {
    /// The cost report request, as a closure: tests hand the provider a payload, so a
    /// test run never opens a connection or needs a key. The default is the HTTP
    /// client with the two retries this provider has always allowed.
    typealias CostReportFetch = @Sendable (_ url: URL, _ headers: [String: String]) async throws -> Data

    let serviceID = "anthropic-admin"
    private let adminKey: String
    private let fetchCostReport: CostReportFetch

    /// Amounts are API text, not the user's: the decimal point is always ".".
    private static let posix = Locale(identifier: "en_US_POSIX")

    init(
        adminKey: String,
        fetchCostReport: @escaping CostReportFetch = { url, headers in
            try await HTTPClient().getRaw(url, headers: headers, maxRetries: 2)
        }
    ) {
        self.adminKey = adminKey
        self.fetchCostReport = fetchCostReport
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
            let data = try await fetchCostReport(costURL, headers)
            let cost = try Self.decodeReport(data)
            // The report is in cents. Add them up exactly and turn the sum into
            // dollars once, so a week of rows carries no binary rounding.
            var cents = Decimal.zero
            for bucket in cost.data {
                for result in bucket.results {
                    if let text = result.amount, let amount = Decimal(string: text, locale: Self.posix) {
                        cents += amount
                    }
                }
            }
            let weekCost = NSDecimalNumber(decimal: cents / 100).doubleValue

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

    /// The decoder and the error `HTTPClient.get` used before the request became
    /// injectable, so a report that does not decode still reads "Decoding failed: …".
    private static func decodeReport(_ data: Data) throws -> CostReportResponse {
        do {
            return try JSONDecoder.usageTracker.decode(CostReportResponse.self, from: data)
        } catch {
            throw HTTPClientError.decoding(String(describing: error))
        }
    }
}
