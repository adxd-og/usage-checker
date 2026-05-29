import Foundation

private struct OAuthUsageResponse: Decodable, Sendable {
    let fiveHour: WindowDTO?
    let sevenDay: WindowDTO?
    let sevenDayOpus: WindowDTO?
    let sevenDaySonnet: WindowDTO?
    let sevenDayOmelette: WindowDTO?      // "Claude Design" weekly
    let sevenDayCowork: WindowDTO?         // Cowork weekly
    let sevenDayOauthApps: WindowDTO?      // OAuth apps weekly
    let extraUsage: ExtraDTO?

    struct WindowDTO: Decodable, Sendable {
        let utilization: Double?
        let resetsAt: Date?
        let usedPercentage: Double?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
            case usedPercentage = "used_percentage"
        }

        var normalizedPercent: Double? {
            let raw = utilization ?? usedPercentage
            guard let v = raw else { return nil }
            return v <= 1.0 ? v * 100.0 : v
        }
    }

    struct ExtraDTO: Decodable, Sendable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOmelette = "seven_day_omelette"
        case sevenDayCowork = "seven_day_cowork"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case extraUsage = "extra_usage"
    }
}

final class ClaudeOAuthProvider: UsageProvider, Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let userAgent = "claude-code/2.1.149"

    let serviceID = "claude"
    private let http: HTTPClient
    private let refresher: OAuthRefreshClient
    private let betaHeader: String

    init(
        http: HTTPClient = HTTPClient(),
        refresher: OAuthRefreshClient = OAuthRefreshClient(),
        betaHeader: String = "oauth-2025-04-20"
    ) {
        self.http = http
        self.refresher = refresher
        self.betaHeader = betaHeader
    }

    func fetch() async -> ServiceSnapshot {
        let now = Date()
        let creds: ClaudeCredentials
        do {
            creds = try ClaudeKeychainReader.read()
        } catch {
            return .notSignedIn(message: error.localizedDescription, at: now)
        }

        var accessToken = creds.claudeAiOauth.accessToken
        let expiresAt = creds.claudeAiOauth.expiresAt
        let nowMs = now.timeIntervalSince1970 * 1000

        if nowMs > expiresAt - 5 * 60 * 1000, let refresh = creds.claudeAiOauth.refreshToken {
            if let refreshed = try? await refresher.refresh(refreshToken: refresh, userAgent: Self.userAgent) {
                accessToken = refreshed.accessToken
            }
        }

        let resp: OAuthUsageResponse
        do {
            resp = try await fetchUsage(token: accessToken)
        } catch HTTPClientError.badStatus(401, _) {
            guard let refreshToken = creds.claudeAiOauth.refreshToken else {
                return .errorState(message: "Unauthorized and no refresh token", at: now)
            }
            do {
                let refreshed = try await refresher.refresh(refreshToken: refreshToken, userAgent: Self.userAgent)
                resp = try await fetchUsage(token: refreshed.accessToken)
            } catch {
                return .errorState(message: error.localizedDescription, at: now)
            }
        } catch HTTPClientError.rateLimited(let retryAfter) {
            return .errorState(message: "Rate limited by usage API", at: now, retryAfter: retryAfter ?? 60)
        } catch {
            return .errorState(message: error.localizedDescription, at: now)
        }

        let tier = SubscriptionTier(
            rawSubscriptionType: creds.claudeAiOauth.subscriptionType,
            rateLimitTier: creds.claudeAiOauth.rateLimitTier
        )

        var buckets: [UsageBucket] = []

        if let b = bucket(id: "five_hour",  label: "Current session", from: resp.fiveHour,  kind: .session) {
            buckets.append(b)
        }
        if let b = bucket(id: "seven_day",  label: "All models",      from: resp.sevenDay,  kind: .weekly) {
            buckets.append(b)
        }
        if let b = bucket(id: "seven_day_opus",   label: "Opus only",     from: resp.sevenDayOpus,   kind: .modelSpecific) {
            buckets.append(b)
        }
        if let b = bucket(id: "seven_day_sonnet", label: "Sonnet only",   from: resp.sevenDaySonnet, kind: .modelSpecific) {
            buckets.append(b)
        }
        if let b = bucket(id: "seven_day_omelette", label: "Claude Design", from: resp.sevenDayOmelette, kind: .modelSpecific) {
            buckets.append(b)
        }
        if let b = bucket(id: "seven_day_cowork",   label: "Cowork",        from: resp.sevenDayCowork,   kind: .modelSpecific) {
            buckets.append(b)
        }
        if let b = bucket(id: "seven_day_oauth_apps", label: "OAuth apps",  from: resp.sevenDayOauthApps, kind: .modelSpecific) {
            buckets.append(b)
        }

        let extra: ExtraUsage? = {
            guard let e = resp.extraUsage else { return nil }
            let monthlyLimit = e.monthlyLimit ?? 0
            let usedCredits = e.usedCredits ?? 0
            // Normalize to 0–100 to match UsageBucket.utilization. Prefer the unambiguous
            // used/limit ratio so the bar always agrees with the "$X / $Y" text beside it;
            // fall back to the raw utilization field (a 0–1 fraction from the API).
            let util: Double = {
                if monthlyLimit > 0 { return min(100, usedCredits / monthlyLimit * 100) }
                let u = e.utilization ?? 0
                return u <= 1.0 ? u * 100 : u
            }()
            return ExtraUsage(
                isEnabled: e.isEnabled ?? false,
                monthlyLimit: monthlyLimit,
                usedCredits: usedCredits,
                utilization: util
            )
        }()

        return ServiceSnapshot(
            id: serviceID,
            displayName: "Claude",
            icon: "sparkles",
            plan: tier.displayName,
            accountLabel: nil,
            buckets: buckets,
            extraUsage: extra,
            weekCost: nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: now
        )
    }

    private func bucket(id: String, label: String, from dto: OAuthUsageResponse.WindowDTO?, kind: BucketKind) -> UsageBucket? {
        guard let dto else { return nil }
        guard let p = dto.normalizedPercent else { return nil }
        let resets = dto.resetsAt ?? Date.distantFuture
        return UsageBucket(id: id, label: label, utilization: p, resetsAt: resets, kind: kind)
    }

    private func fetchUsage(token: String) async throws -> OAuthUsageResponse {
        let headers = [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": betaHeader,
            "anthropic-version": "2023-06-01",
            "User-Agent": Self.userAgent,
            "Accept": "application/json",
        ]
        return try await http.get(
            Self.usageURL,
            headers: headers,
            as: OAuthUsageResponse.self,
            maxRetries: 3
        )
    }
}

extension ServiceSnapshot {
    static func notSignedIn(message: String, at date: Date) -> ServiceSnapshot {
        ServiceSnapshot(
            id: "claude",
            displayName: "Claude",
            icon: "sparkles",
            plan: nil,
            accountLabel: nil,
            buckets: [],
            extraUsage: nil,
            weekCost: nil,
            state: .notSignedIn,
            stateMessage: message,
            fetchedAt: date
        )
    }

    static func errorState(message: String, at date: Date, retryAfter: TimeInterval? = nil) -> ServiceSnapshot {
        ServiceSnapshot(
            id: "claude",
            displayName: "Claude",
            icon: "sparkles",
            plan: nil,
            accountLabel: nil,
            buckets: [],
            extraUsage: nil,
            weekCost: nil,
            state: .error,
            stateMessage: message,
            fetchedAt: date,
            retryAfter: retryAfter
        )
    }
}
