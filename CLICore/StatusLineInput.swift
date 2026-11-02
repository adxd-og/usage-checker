import Foundation

/// What Claude Code tells us about the session it is drawing a status line for.
///
/// It writes a JSON object to our stdin and closes the pipe. Three things in it are
/// worth a status line: the model's display name, how full the context window is, and
/// how long the prompt cache stays warm. The account's 5-hour and weekly rate limits
/// are read too, for the app rather than for the line. Everything else in that object
/// is Claude Code's business.
///
/// The payload is somebody else's format and may change under us, so every shape that
/// is not the one we expect — a missing key, an id where a name belongs, a number
/// written as a string, invalid JSON, an empty pipe — resolves to `nil` rather than to
/// an error. A status line has no place to report a parse failure, and a session spent
/// looking at one would be worse than a session spent looking at nothing.
struct StatusLineInput: Equatable, Sendable {
    /// `model.display_name` — "Fable", "Opus 4.5". Never the id: it is what Claude
    /// Code itself prints, and an id in a status bar is noise.
    let model: String?

    /// `context_window.used_percentage`, clamped to 0…100. **Used**, always: this is
    /// the session's context window filling up, a different quantity from the
    /// rate-limit windows beside it, so `PercentDisplay.Mode` — which flips those
    /// between "used" and "left" — deliberately does not apply to it. A context bar
    /// that inverted with that setting would read as a limit the user does not have.
    let contextUsedPercent: Double?

    /// `prompt_cache` — Claude Code's own reading of the session's prompt cache,
    /// computed from the API's cache counters. Absent until the main conversation's
    /// first API response and on Claude Code before 2.1.251, and nil then; nil too when
    /// the object is not the shape `PromptCache` describes.
    let promptCache: PromptCache?

    /// The four fields of `prompt_cache` the cache timer needs. `hit_ratio`, the miss
    /// fields and the counters stay Claude Code's business.
    struct PromptCache: Equatable, Sendable {
        /// `warm` — the cached prefix is still inside its TTL. `false` when the last
        /// response reported no cache tokens.
        let warm: Bool
        /// `ttl` — "5m" or "1h", trimmed. Anything else is kept as given; the rule
        /// treats it as the default TTL.
        let ttl: String?
        /// `expires_at` — when the cached prefix leaves its TTL and goes cold. Epoch
        /// seconds as a number or a numeric string; `null` or absent is nil.
        let expiresAt: Date?
        /// `caching_observed` — whether Claude Code has seen cache tokens in this
        /// session at all. `false` is nothing to count, not a cold cache.
        let cachingObserved: Bool
    }

    /// `rate_limits` — the account's 5-hour and weekly windows as of the last API
    /// response Claude Code received. Only on Pro, Max and Ultra, and only after the
    /// session's first API response; nil then, and nil when neither window is the shape
    /// `RateLimits.Window` describes. The line does not draw it; the app gets it through
    /// the status line's reading drop.
    let rateLimits: RateLimits?

    /// The two windows of `rate_limits`, each present only when Claude Code knows it;
    /// the parser never returns one with both nil. `spend_limit`, which only a gateway
    /// sends, stays Claude Code's business.
    struct RateLimits: Equatable, Sendable {
        /// `five_hour`.
        let fiveHour: Window?
        /// `seven_day`.
        let sevenDay: Window?

        /// Both fields or no window: a window without its reset is not the documented
        /// shape, and the app would have nothing to age it by.
        struct Window: Equatable, Sendable {
            /// `used_percentage`, clamped to 0…100. Claude Code rounds it to one decimal
            /// (`Math.round(utilization * 1000) / 10`) and the decimal is kept.
            let usedPercent: Double
            /// `resets_at` — epoch seconds, as a JSON number or a numeric string.
            let resetsAt: Date
        }
    }

    init(
        model: String?,
        contextUsedPercent: Double?,
        promptCache: PromptCache? = nil,
        rateLimits: RateLimits? = nil
    ) {
        self.model = model
        self.contextUsedPercent = contextUsedPercent
        self.promptCache = promptCache
        self.rateLimits = rateLimits
    }

    /// Nothing was piped in, or nothing in it was ours.
    static let none = StatusLineInput(model: nil, contextUsedPercent: nil)

    static func parse(_ data: Data) -> StatusLineInput {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return .none }
        return StatusLineInput(
            model: name(root["model"]),
            contextUsedPercent: percent((root["context_window"] as? [String: Any])?["used_percentage"]),
            promptCache: readPromptCache(root["prompt_cache"]),
            rateLimits: readRateLimits(root["rate_limits"])
        )
    }

    private static func name(_ value: Any?) -> String? {
        guard let model = value as? [String: Any] else { return nil }
        return text(model["display_name"])
    }

    private static func percent(_ value: Any?) -> Double? {
        number(value).map { max(0, min(100, $0)) }
    }

    /// The flags must be JSON booleans and the expiry a time, `null` or absent.
    /// Anything else is a payload we do not understand, and guessing would draw a
    /// timer — or a "cache cold" — that Claude Code never reported.
    ///
    /// Named apart from the `promptCache` property so a static call can never be read
    /// as the instance member.
    private static func readPromptCache(_ value: Any?) -> PromptCache? {
        guard let cache = value as? [String: Any],
              let warm = boolean(cache["warm"]),
              let cachingObserved = boolean(cache["caching_observed"])
        else { return nil }
        let expiry = cache["expires_at"]
        let expiresAt = number(expiry).map { Date(timeIntervalSince1970: $0) }
        guard expiresAt != nil || expiry == nil || expiry is NSNull else { return nil }
        return PromptCache(
            warm: warm,
            ttl: text(cache["ttl"]),
            expiresAt: expiresAt,
            cachingObserved: cachingObserved
        )
    }

    /// nil unless at least one window reads: an object with neither — `{}`, a
    /// gateway's `spend_limit` alone — has nothing for the app.
    private static func readRateLimits(_ value: Any?) -> RateLimits? {
        guard let limits = value as? [String: Any] else { return nil }
        let fiveHour = readWindow(limits["five_hour"])
        let sevenDay = readWindow(limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return RateLimits(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    /// A percent and a reset, or no window. A window we cannot read costs that window,
    /// not its neighbour and not the line.
    private static func readWindow(_ value: Any?) -> RateLimits.Window? {
        guard let window = value as? [String: Any],
              let usedPercent = percent(window["used_percentage"]),
              let resetsAt = number(window["resets_at"])
        else { return nil }
        return RateLimits.Window(usedPercent: usedPercent, resetsAt: Date(timeIntervalSince1970: resetsAt))
    }

    /// A string, trimmed; nil when it is not a string or nothing is left of it.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A finite number, written as a JSON number or as a numeric string.
    private static func number(_ value: Any?) -> Double? {
        // `true` bridges to 1.0 and would draw a bar or a date. A boolean here is a
        // payload we do not understand, not a one.
        guard let value, !isBoolean(value) else { return nil }
        let number: Double?
        if let text = value as? String {
            number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            number = (value as? NSNumber)?.doubleValue
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    /// A JSON `true` or `false`, and nothing that merely bridges to one: `1`, `"true"`.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, isBoolean(value) else { return nil }
        return value as? Bool
    }

    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}
