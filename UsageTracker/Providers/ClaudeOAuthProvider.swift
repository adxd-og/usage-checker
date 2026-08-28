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

    /// A dollar-denominated pool, not a rate-limit window.
    ///
    /// The live payload carries `nimbus_quill` at the top level next to the real
    /// windows: `{"utilization": 0.0, "resets_at": null, "limit_dollars": null,
    /// "used_dollars": null, "remaining_dollars": null}`. It reports `utilization`
    /// exactly the way a window does, so the generic decoder below happily published it
    /// as a "Nimbus Quill 0%" bar in the popover, the widget and the history log — on
    /// accounts where the pool isn't even switched on.
    ///
    /// The dollar keys are the tell, and they identify the object even when every one of
    /// their values is null, so presence is checked on the container rather than on the
    /// decoded values.
    struct DollarPoolDTO: Decodable, Sendable {
        let isDollarPool: Bool
        let utilization: Double?
        let resetsAt: Date?
        let limitDollars: Double?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
            case limitDollars = "limit_dollars"
            case usedDollars = "used_dollars"
            case remainingDollars = "remaining_dollars"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isDollarPool = c.contains(.limitDollars)
                || c.contains(.usedDollars)
                || c.contains(.remainingDollars)
            utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
            limitDollars = try? c.decodeIfPresent(Double.self, forKey: .limitDollars)
        }

        /// The pool is worth a bar only when there is real money behind it: a null or
        /// zero `limit_dollars` is a pool the account doesn't have.
        var asWindow: WindowDTO? {
            guard let limit = limitDollars, limit > 0, let utilization else { return nil }
            return WindowDTO(utilization: utilization, resetsAt: resetsAt, usedPercentage: nil)
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
            if let pool = try? c.decode(DollarPoolDTO.self, forKey: key), pool.isDollarPool {
                // A dollar pool is either a real limit or nothing at all — never a 0%
                // bar. `spend` (the usage-credits object) has no dollar keys of this
                // shape and no `utilization`, so it falls through and is skipped below.
                if let window = pool.asWindow { windows[key.stringValue] = window }
                continue
            }
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
    /// The usage endpoint is undocumented and identifies callers by Claude Code's own
    /// User-Agent. Keep this roughly in step with the shipping CLI — a version far in
    /// the past is the first thing a server-side filter would reject.
    static let userAgent = "claude-code/2.1.247"

    let serviceID = "claude"
    private let http: HTTPClient
    private let betaHeader: String

    init(
        http: HTTPClient = HTTPClient(),
        betaHeader: String = "oauth-2025-04-20"
    ) {
        self.http = http
        self.betaHeader = betaHeader
    }

    func fetch() async -> ServiceSnapshot {
        let now = Date()
        var oauth: ClaudeCredentials.OAuth
        do {
            oauth = try resolveCredentials(now: now)
        } catch {
            return .notSignedIn(message: error.localizedDescription, at: now)
        }

        let resp: OAuthUsageResponse
        do {
            resp = try await fetchUsage(token: oauth.accessToken)
        } catch HTTPClientError.badStatus(401, _) {
            // The token is dead and refreshing it is Claude Code's job, not ours. Give
            // its sources one more look — it may have rotated already — and otherwise
            // report a signed-out state. The cache is deliberately NOT cleared: on a
            // machine with no credentials file it is the only copy we have, and
            // dropping it would force the next poll back onto an interactive read.
            guard let renewed = Self.newestFromClaudeCode(beating: nil),
                  Self.isUsableRenewal(renewed, after: oauth)
            else {
                return .notSignedIn(
                    message: "Claude Code session expired — run `claude` once to renew it",
                    at: now
                )
            }
            ClaudeCredentialsCache.save(renewed)
            oauth = renewed
            do {
                resp = try await fetchUsage(token: renewed.accessToken)
            } catch {
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

        let buckets = Self.buckets(from: resp)
        let extra = Self.extraUsage(from: resp)

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

    /// Resolves OAuth credentials without ever putting a keychain dialog on screen.
    ///
    /// Claude Code owns the refresh lifecycle — it *rotates* its refresh token, so
    /// refreshing on our own would invalidate the CLI's copy and steal the session
    /// (and lose the race the other half of the time). We only ever read, cheapest
    /// source first: our own cache → the credentials file (no keychain at all) →
    /// a silent probe of Claude Code's item. Every one of those is prompt-proof;
    /// the interactive read lives behind the Settings button alone.
    private func resolveCredentials(now: Date) throws -> ClaudeCredentials.OAuth {
        let cached = ClaudeCredentialsCache.load()?.claudeAiOauth
        if let cached, !Self.isExpired(cached, at: now) { return cached }

        // Cache missing or stale: ask Claude Code what it has now.
        if let fresh = Self.newestFromClaudeCode(beating: cached) {
            ClaudeCredentialsCache.save(fresh)
            return fresh
        }
        // Nothing newer anywhere. An expired cached token still beats no token: the
        // usage API is the authority on whether it's really dead, and a 401 there is
        // recoverable, whereas throwing here would blank the menu bar.
        if let cached { return cached }

        // Truly nothing to work with — say which of the two situations this is.
        throw ClaudeKeychainReader.itemExists()
            ? ClaudeKeychainError.interactionRequired
            : ClaudeKeychainError.notFound
    }

    /// Newest credentials Claude Code currently exposes, or nil when nothing it has
    /// beats `best`. Pass nil to get the newest regardless. Never prompts.
    private static func newestFromClaudeCode(
        beating best: ClaudeCredentials.OAuth?
    ) -> ClaudeCredentials.OAuth? {
        var winner: ClaudeCredentials.OAuth?
        var bestExpiry = best?.expiresAt ?? 0
        // File first: it needs no keychain access, so it can't fail on an ACL.
        if let file = ClaudeKeychainReader.readFromFile()?.claudeAiOauth, file.expiresAt > bestExpiry {
            winner = file
            bestExpiry = file.expiresAt
        }
        if let probed = try? ClaudeKeychainReader.readNonInteractive().claudeAiOauth,
           probed.expiresAt > bestExpiry {
            winner = probed
        }
        return winner
    }

    /// Whether credentials found after a 401 are worth swapping in.
    ///
    /// The 401 path re-reads Claude Code's sources with no "beat this" floor, because
    /// the token that just failed may still be the newest thing on disk. That leaves it
    /// open to going *backwards*: a stale `~/.claude/.credentials.json` holding an older
    /// token than the one in the cache would win on the "different token" test alone and
    /// overwrite the cache with something even deader.
    ///
    /// `>=` rather than `>` on the expiry so a rotation landing in the same millisecond
    /// still counts — the access token is what has to differ.
    static func isUsableRenewal(
        _ candidate: ClaudeCredentials.OAuth,
        after expired: ClaudeCredentials.OAuth
    ) -> Bool {
        candidate.expiresAt >= expired.expiresAt && candidate.accessToken != expired.accessToken
    }

    /// Treats the token as expired a few minutes early, so a poll doesn't spend its
    /// request on a token that dies mid-flight.
    private static func isExpired(_ oauth: ClaudeCredentials.OAuth, at now: Date) -> Bool {
        now.timeIntervalSince1970 * 1000 > oauth.expiresAt - 5 * 60 * 1000
    }

    /// User-initiated keychain read (the Settings button): the only path in the app
    /// allowed to show the macOS permission dialog. Caches on success — the next poll
    /// picks the credentials up.
    static func forceKeychainRead() throws {
        let oauth = try ClaudeKeychainReader.read().claudeAiOauth
        ClaudeCredentialsCache.save(oauth)
    }

    // MARK: - Payload → model

    /// The one door into the payload-shaping logic that doesn't need a network
    /// round-trip: `OAuthUsageResponse` and the builders below stay private, and
    /// the tests exercise exactly the path `fetch()` takes.
    static func usage(fromPayload data: Data) throws -> (buckets: [UsageBucket], extraUsage: ExtraUsage?) {
        let resp = try JSONDecoder.usageTracker.decode(OAuthUsageResponse.self, from: data)
        return (buckets(from: resp), extraUsage(from: resp))
    }

    /// The modern `limits` array is the source of truth when present (scoped
    /// windows exist only there); legacy top-level windows it doesn't cover
    /// (promotional pools) are appended after. An empty/missing array means
    /// the exact pre-`limits` behavior.
    private static func buckets(from resp: OAuthUsageResponse) -> [UsageBucket] {
        let limitBuckets = buckets(fromLimits: resp.limits)
        guard !limitBuckets.isEmpty else { return buckets(from: resp.windows) }
        let taken = Set(limitBuckets.map(\.id))
        return limitBuckets + buckets(from: resp.windows).filter { !taken.contains($0.id) }
    }

    private static func extraUsage(from resp: OAuthUsageResponse) -> ExtraUsage? {
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
