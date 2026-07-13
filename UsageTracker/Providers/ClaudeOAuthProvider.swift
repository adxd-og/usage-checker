import Foundation

private struct OAuthUsageResponse: Decodable, Sendable {
    /// Every rate-limit window in the payload, keyed by its JSON field name. Decoded
    /// dynamically so a window added server-side (a new model family, a new product
    /// surface) shows up in the app without a code change.
    let windows: [String: WindowDTO]
    let extraUsage: ExtraDTO?
    let limits: [LimitDTO]

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
            // The usage API reports these as a PERCENT already (0–100): a value of 1.0
            // means 1%, not 100%. This used to multiply values <= 1.0 by 100 (assuming a
            // 0–1 fraction), which turned a genuine 1% into 100% on low-usage windows
            // like "Sonnet only". Bounds are clamped downstream via clampedPercent.
            utilization ?? usedPercentage
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

    /// One entry of the modern `limits` array (server-side since ~July 2026).
    /// Scoped windows (e.g. Fable's weekly cap) exist ONLY here — their legacy
    /// per-key fields arrive as null. `severity`/`is_active`/`surface` are
    /// deliberately not decoded: the UI derives urgency from the percent.
    struct LimitDTO: Decodable, Sendable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: Date?
        let scope: ScopeDTO?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, scope
            case resetsAt = "resets_at"
        }

        struct ScopeDTO: Decodable, Sendable {
            let model: ModelDTO?

            struct ModelDTO: Decodable, Sendable {
                let id: String?
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case id
                    case displayName = "display_name"
                }
            }
        }

        /// Display-ready scope name when the limit is model-scoped: "Fable".
        var scopeName: String? {
            let name = scope?.model?.displayName ?? scope?.model?.id
            return name?.isEmpty == false ? name : nil
        }
    }

    /// Swallows per-element decode failures so one unexpected entry in
    /// `limits` can't hide the rest of the array.
    private struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
        let value: T?
        init(from decoder: Decoder) {
            self.value = try? T(from: decoder)
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var windows: [String: WindowDTO] = [:]
        for key in c.allKeys where key.stringValue != "extra_usage" {
            // `extra_usage` also carries a `utilization` field, hence the by-name skip
            // above; anything else that decodes as a window object and reports a percent
            // is treated as one.
            guard let dto = try? c.decode(WindowDTO.self, forKey: key),
                  dto.normalizedPercent != nil else { continue }
            windows[key.stringValue] = dto
        }
        self.windows = windows
        self.limits = (AnyKey(stringValue: "limits").flatMap {
            try? c.decodeIfPresent([Lossy<LimitDTO>].self, forKey: $0)
        } ?? []).compactMap(\.value)
        self.extraUsage = AnyKey(stringValue: "extra_usage").flatMap {
            try? c.decodeIfPresent(ExtraDTO.self, forKey: $0)
        }
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
        let oauth: ClaudeCredentials.OAuth
        do {
            oauth = try await resolveCredentials(now: now)
        } catch {
            return .notSignedIn(message: error.localizedDescription, at: now)
        }

        let resp: OAuthUsageResponse
        do {
            resp = try await fetchUsage(token: oauth.accessToken)
        } catch HTTPClientError.badStatus(401, _) {
            guard let refreshToken = oauth.refreshToken else {
                ClaudeCredentialsCache.clear()
                return .errorState(message: "Unauthorized and no refresh token", at: now)
            }
            do {
                let refreshed = try await refresher.refresh(refreshToken: refreshToken, userAgent: Self.userAgent)
                let merged = Self.merged(oauth, with: refreshed, at: now)
                ClaudeCredentialsCache.save(merged)
                resp = try await fetchUsage(token: merged.accessToken)
            } catch {
                // Both the token and its refresh are dead — drop the cache so the next
                // poll re-bootstraps from Claude Code's sources.
                ClaudeCredentialsCache.clear()
                return .errorState(message: error.localizedDescription, at: now)
            }
        } catch HTTPClientError.rateLimited(let retryAfter) {
            return .errorState(message: "Rate limited by usage API", at: now, retryAfter: retryAfter ?? 60)
        } catch {
            return .errorState(message: error.localizedDescription, at: now)
        }

        let tier = SubscriptionTier(
            rawSubscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )

        // The modern `limits` array is the source of truth when present (scoped
        // windows exist only there); legacy top-level windows it doesn't cover
        // (promotional pools) are appended after. An empty/missing array means
        // the exact pre-`limits` behavior.
        let limitBuckets = Self.buckets(fromLimits: resp.limits)
        let buckets: [UsageBucket]
        if limitBuckets.isEmpty {
            buckets = Self.buckets(from: resp.windows)
        } else {
            let taken = Set(limitBuckets.map(\.id))
            buckets = limitBuckets + Self.buckets(from: resp.windows).filter { !taken.contains($0.id) }
        }

        let extra: ExtraUsage? = {
            guard let e = resp.extraUsage else { return nil }
            // The API reports these in CENTS: an Enterprise account showing
            // "$156.40 of $200.00" in Claude's own UI arrives here as
            // used_credits=15640, monthly_limit=20000.
            let monthlyLimit = (e.monthlyLimit ?? 0) / 100
            let usedCredits = (e.usedCredits ?? 0) / 100
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

    // MARK: - Credentials

    /// Resolves OAuth credentials prompt-lessly wherever possible.
    ///
    /// Claude Code re-creates its keychain item on every token refresh (~8h), resetting the
    /// ACL — so a plain read used to re-prompt the user that often. Order here: our own
    /// cache → silent probe of Claude Code's item (picks up re-logins for free while the
    /// ACL lasts) → the credentials file → interactive read (may prompt, cooldown-limited).
    /// Expired tokens are refreshed by us and cached, so we stay off Claude Code's item.
    private func resolveCredentials(now: Date) async throws -> ClaudeCredentials.OAuth {
        var best = ClaudeCredentialsCache.load()?.claudeAiOauth

        if let probed = try? ClaudeKeychainReader.readNonInteractive().claudeAiOauth,
           probed.expiresAt > (best?.expiresAt ?? 0) {
            best = probed
            ClaudeCredentialsCache.save(probed)
        }
        if best == nil, let file = ClaudeKeychainReader.readFromFile()?.claudeAiOauth {
            best = file
            ClaudeCredentialsCache.save(file)
        }
        if best == nil {
            best = try interactiveRead(now: now)
        }
        guard var oauth = best else { throw ClaudeKeychainError.notFound }

        let nowMs = now.timeIntervalSince1970 * 1000
        if nowMs > oauth.expiresAt - 5 * 60 * 1000, let refreshToken = oauth.refreshToken {
            if let refreshed = try? await refresher.refresh(refreshToken: refreshToken, userAgent: Self.userAgent) {
                oauth = Self.merged(oauth, with: refreshed, at: now)
                ClaudeCredentialsCache.save(oauth)
            }
        }
        return oauth
    }

    /// UserDefaults key holding the last interactive keychain attempt timestamp.
    private static let promptCooldownKey = "claudeKeychainPromptAt"

    /// Interactive keychain read — the only path that can show the permission prompt.
    /// Rate-limited so background polling can't turn a Deny into a prompt storm.
    private func interactiveRead(now: Date) throws -> ClaudeCredentials.OAuth {
        let last = UserDefaults.standard.double(forKey: Self.promptCooldownKey)
        guard now.timeIntervalSince1970 - last >= 3600 else {
            throw ClaudeKeychainError.interactionRequired
        }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.promptCooldownKey)
        let oauth = try ClaudeKeychainReader.read().claudeAiOauth
        ClaudeCredentialsCache.save(oauth)
        return oauth
    }

    /// User-initiated keychain read (the Settings button): skips the hourly
    /// prompt cooldown, may show the macOS permission dialog right away, and
    /// re-arms the cooldown either way so background polling stays quiet after
    /// a Deny. Caches on success — the next poll picks the credentials up.
    static func forceKeychainRead() throws {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: promptCooldownKey)
        let oauth = try ClaudeKeychainReader.read().claudeAiOauth
        ClaudeCredentialsCache.save(oauth)
    }

    private static func merged(
        _ oauth: ClaudeCredentials.OAuth,
        with refreshed: OAuthTokenResponse,
        at now: Date
    ) -> ClaudeCredentials.OAuth {
        ClaudeCredentials.OAuth(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? oauth.refreshToken,
            expiresAt: now.timeIntervalSince1970 * 1000 + Double(refreshed.expiresIn ?? 3600) * 1000,
            scopes: oauth.scopes,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    /// Display metadata for the windows we know about; also fixes their order in the UI.
    private static let knownWindows: [(id: String, label: String, kind: BucketKind)] = [
        ("five_hour", "Current session", .session),
        ("seven_day", "All models", .weekly),
        ("seven_day_opus", "Opus only", .modelSpecific),
        ("seven_day_sonnet", "Sonnet only", .modelSpecific),
        ("seven_day_fable", "Fable only", .modelSpecific),
        ("seven_day_omelette", "Claude Design", .modelSpecific),
        ("seven_day_cowork", "Cowork", .modelSpecific),
        ("seven_day_oauth_apps", "OAuth apps", .modelSpecific),
    ]

    private static func buckets(from windows: [String: OAuthUsageResponse.WindowDTO]) -> [UsageBucket] {
        var remaining = windows
        var buckets: [UsageBucket] = []

        for known in knownWindows {
            guard let dto = remaining.removeValue(forKey: known.id),
                  let p = dto.normalizedPercent else { continue }
            buckets.append(UsageBucket(
                id: known.id,
                label: known.label,
                utilization: p,
                resetsAt: dto.resetsAt ?? .distantFuture,
                kind: known.kind
            ))
        }

        // Windows this build doesn't know by name (a new model's weekly cap, a new
        // surface) still get shown, with a label derived from the key.
        for (key, dto) in remaining.sorted(by: { $0.key < $1.key }) {
            guard let p = dto.normalizedPercent else { continue }
            buckets.append(UsageBucket(
                id: key,
                label: autoLabel(for: key),
                utilization: p,
                resetsAt: dto.resetsAt ?? .distantFuture,
                kind: autoKind(for: key)
            ))
        }
        return buckets
    }

    /// Buckets from the modern `limits` array. Ids reuse the keys the app has
    /// published since v1.1.0 so history records, the widget, and threshold
    /// notifications stay continuous.
    private static func buckets(fromLimits limits: [OAuthUsageResponse.LimitDTO]) -> [UsageBucket] {
        var seen = Set<String>()
        var buckets: [UsageBucket] = []
        for limit in limits {
            guard let percent = limit.percent else { continue }
            let identity = identity(for: limit)
            // A duplicated server entry must not produce duplicate Identifiable
            // ids in SwiftUI lists — first occurrence wins.
            guard seen.insert(identity.id).inserted else { continue }
            buckets.append(UsageBucket(
                id: identity.id,
                label: identity.label,
                utilization: percent,
                resetsAt: limit.resetsAt ?? .distantFuture,
                kind: identity.kind
            ))
        }
        return buckets
    }

    private static func identity(
        for limit: OAuthUsageResponse.LimitDTO
    ) -> (id: String, label: String, kind: BucketKind) {
        let scopeName = limit.scopeName.map(Self.displayScopeName)
        let scopeSlug = limit.scopeName.map(Self.slug)
        switch limit.kind {
        case "session":
            return ("five_hour", "Current session", .session)
        case "weekly_all":
            return ("seven_day", "All models", .weekly)
        case "weekly_scoped":
            guard let scopeName, let scopeSlug else {
                return ("seven_day_scoped", "Model-specific", .modelSpecific)
            }
            return ("seven_day_\(scopeSlug)", "\(scopeName) only", .modelSpecific)
        default:
            // A future kind still renders: id from kind (+ scope slug), label
            // from the scope name or the kind's words.
            let kindName = limit.kind ?? "limit"
            let id = scopeSlug.map { "\(kindName)_\($0)" } ?? kindName
            let label = scopeName.map { "\($0) only" }
                ?? kindName.split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
            let bucketKind: BucketKind = {
                switch limit.group {
                case "session": return .session
                case "weekly": return scopeName == nil ? .weekly : .modelSpecific
                default: return autoKind(for: kindName)
                }
            }()
            return (id, label, bucketKind)
        }
    }

    /// "Fable" → "fable", "Claude Design" → "claude_design".
    private static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    /// Keeps Anthropic's internal codenames out of the UI, mirroring autoLabel:
    /// a scope named "omelette" is Claude Design.
    private static func displayScopeName(_ name: String) -> String {
        name.lowercased() == "omelette" ? "Claude Design" : name
    }

    /// "seven_day_fable" → "Fable only", "seven_day_code_review" → "Code Review".
    private static func autoLabel(for key: String) -> String {
        var stem = key
        let weeklyPrefix = "seven_day_"
        let isWeeklySub = stem.hasPrefix(weeklyPrefix)
        if isWeeklySub { stem.removeFirst(weeklyPrefix.count) }
        let words = stem.split(separator: "_").map { word -> String in
            // Anthropic's internal codenames shouldn't leak into the UI:
            // "omelette" is Claude Design (e.g. "seven_day_omelette_promotional").
            word == "omelette" ? "Claude Design" : String(word).capitalized
        }
        if isWeeklySub && words.count == 1 { return "\(words[0]) only" }
        return words.joined(separator: " ")
    }

    private static func autoKind(for key: String) -> BucketKind {
        if key.hasPrefix("seven_day_") { return .modelSpecific }
        if key.contains("day") || key.contains("week") { return .weekly }
        if key.contains("hour") || key.contains("session") { return .session }
        return .other
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
