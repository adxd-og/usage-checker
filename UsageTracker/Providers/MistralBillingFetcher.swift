import Foundation

/// What Mistral's billing API answered (spec 2026-11-10 Mistral provider § Fetch).
struct MistralBilling: Equatable, Sendable {
    /// `plan_name` from `/v1/billing/subscription`; nil when that call failed or did not say.
    var planName: String?
    var budget: Budget

    /// `/v1/billing/budget` by what it answered (spec § States).
    enum Budget: Equatable, Sendable {
        /// 200: its `_budget` entries; none when the body holds no such key.
        case entries([MistralBudgetEntry])
        /// 403: the key may not see its organisation's usage (`see_org_inference_usage`).
        case noUsageAccess
        /// 404: a platform without billing.
        case noBilling
    }
}

/// Why `/v1/billing/budget` gave nothing to show. None of its words carries the key or a body.
enum MistralBillingError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case badStatus(Int)
    case transport(String)
    case decoding(String)
}

/// The two GETs vibe reads its plan and budget with (`vibe/app_server/_billing.py`), at once,
/// 10 s each, through an injected transport: a test hands in its answers and opens no
/// connection. The key goes into the `Authorization` header of these two requests to
/// `https://api.mistral.ai` and nowhere else; nothing here logs a request, a header or a body.
/// Not `HTTPClient`: its 15 s and its 5xx retries are not this spec's, and the poll comes again
/// in a minute.
struct MistralBillingFetcher: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let subscriptionURL = URL(string: "https://api.mistral.ai/v1/billing/subscription")!
    static let budgetURL = URL(string: "https://api.mistral.ai/v1/billing/budget")!
    static let timeout: TimeInterval = 10

    var transport: Transport

    /// A session of its own with no URL cache at all. `URLSession.shared` writes a cacheable
    /// answer to `~/Library/Caches/<bundle id>/Cache.db` together with its request — the
    /// `Authorization` header included — and `.reloadIgnoringLocalCacheData` only stops the
    /// reading, not the storing (plan review finding 1). Ephemeral: no cookie or credential
    /// store on disk either.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Every poll asks; nothing comes from a cache and nothing goes into one.
    static let live = MistralBillingFetcher(transport: { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    })

    /// A GET with the key in its `Authorization` header, and nowhere else.
    static func request(_ url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Both calls at once. The plan rides along: a failed `/subscription` leaves it nil and never
    /// fails what `/budget` answered.
    func fetch(apiKey: String) async -> Result<MistralBilling, MistralBillingError> {
        let transport = self.transport
        async let plan = Self.planName(transport: transport, apiKey: apiKey)
        async let budget = Self.budget(transport: transport, apiKey: apiKey)
        let (planName, budgetResult) = await (plan, budget)
        return budgetResult.map { MistralBilling(planName: planName, budget: $0) }
    }

    /// `plan_name`, or nil for any failure.
    static func planName(transport: Transport, apiKey: String) async -> String? {
        guard let answer = try? await transport(request(subscriptionURL, apiKey: apiKey)),
              (200..<300).contains(answer.1.statusCode),
              let body = try? JSONDecoder().decode(SubscriptionBody.self, from: answer.0)
        else { return nil }
        return body.planName
    }

    static func budget(transport: Transport, apiKey: String) async -> Result<MistralBilling.Budget, MistralBillingError> {
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await transport(request(budgetURL, apiKey: apiKey))
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
        return Self.answer(
            status: answer.1.statusCode, body: answer.0, retryAfter: HTTPClient.retryAfterSeconds(answer.1)
        )
    }

    /// One `/budget` answer by its status (spec § States).
    static func answer(
        status: Int, body: Data, retryAfter: TimeInterval?
    ) -> Result<MistralBilling.Budget, MistralBillingError> {
        switch status {
        case 200..<300:
            do {
                return .success(.entries(try decodeBudget(body)))
            } catch {
                return .failure(.decoding(String(describing: error)))
            }
        case 401: return .failure(.unauthorized)
        case 403: return .success(.noUsageAccess)
        case 404: return .success(.noBilling)
        case 429: return .failure(.rateLimited(retryAfter: retryAfter))
        default: return .failure(.badStatus(status))
        }
    }

    /// Every top-level key ending in `_budget` whose value has a numeric `usage_percentage`
    /// (spec § Windows), in no particular order. The top-level duplicates are no such key. Throws
    /// when the body is not a JSON object.
    static func decodeBudget(_ data: Data) throws -> [MistralBudgetEntry] {
        try JSONDecoder().decode(BudgetBody.self, from: data).entries
    }

    private struct SubscriptionBody: Decodable {
        let planName: String?
        enum CodingKeys: String, CodingKey { case planName = "plan_name" }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    private struct BudgetBody: Decodable {
        let entries: [MistralBudgetEntry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            entries = container.allKeys.compactMap { key in
                guard MistralBudgetRules.name(forKey: key.stringValue) != nil,
                      let figures = try? container.decode(Figures.self, forKey: key)
                else { return nil }
                return MistralBudgetEntry(
                    key: key.stringValue,
                    usagePercentage: figures.usagePercentage,
                    initialBudget: figures.initialBudget,
                    currency: figures.currency,
                    resetAt: figures.resetAt
                )
            }
        }
    }

    /// One entry's figures. Only `usage_percentage` must be a number; the others are dropped,
    /// not fatal, when they are missing or of another shape.
    private struct Figures: Decodable {
        let usagePercentage: Double
        let initialBudget: Double?
        let currency: String?
        let resetAt: Date?

        enum CodingKeys: String, CodingKey {
            case usagePercentage = "usage_percentage"
            case initialBudget = "initial_budget"
            case currency
            case resetAt = "reset_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usagePercentage = try c.decode(Double.self, forKey: .usagePercentage)
            initialBudget = (try? c.decodeIfPresent(Double.self, forKey: .initialBudget)) ?? nil
            currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? nil
            resetAt = ((try? c.decodeIfPresent(String.self, forKey: .resetAt)) ?? nil).flatMap(parseFlexibleISODate)
        }
    }
}
