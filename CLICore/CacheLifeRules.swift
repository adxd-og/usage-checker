import Foundation

/// Where a session's prompt cache stands, for the colour of its status-line segment.
enum CacheLifeState: Equatable, Sendable {
    /// Plenty left. Dim, like the percentages beside it.
    case warm
    /// The moment to send one more message before the next turn pays a cache write.
    case closing
    /// Past its TTL, or Claude Code says the last response cached nothing: the next
    /// turn writes the cache again.
    case expired
}

/// `cache 47m` and the state that colours it. The text never carries escape codes;
/// the line adds them when it prints colour.
struct CacheLifeSegment: Equatable, Sendable {
    let text: String
    let state: CacheLifeState
}

/// How long the session's prompt cache stays warm, in the status line's words.
///
/// Anthropic's prompt cache goes cold 5 minutes (default TTL) or 1 hour (extended TTL)
/// after the last request that wrote or read it, and the turn after that pays a full
/// cache write. Claude Code works out the moment from the API's cache counters and
/// pipes it in as `prompt_cache.expires_at`; this rule only turns it into words and a
/// state. CLICore, so Foundation only: the app and the `omelette` CLI both compile it.
enum CacheLifeRules {
    /// An expired cache. Not a negative countdown: the fact worth a glance is that the
    /// next turn pays a write, not how long ago the cache went.
    static let coldText = "cache cold"

    /// The extended TTL as Claude Code spells it in `prompt_cache.ttl`.
    static let extendedTTL = "1h"

    /// On a 1-hour cache the last five minutes are closing; on a 5-minute cache, or one
    /// whose TTL we do not recognise, the last minute is.
    static let extendedClosingWindow: TimeInterval = 5 * 60
    static let defaultClosingWindow: TimeInterval = 60

    /// nil when there is nothing to count: no `prompt_cache` yet (no response, or
    /// Claude Code before 2.1.251), or a session in which caching was never observed —
    /// a "cold" there would blame a cache nobody saw.
    nonisolated static func segment(cache: StatusLineInput.PromptCache?, now: Date) -> CacheLifeSegment? {
        guard let cache, cache.cachingObserved else { return nil }
        guard cache.warm, let expiresAt = cache.expiresAt, expiresAt > now else {
            return CacheLifeSegment(text: coldText, state: .expired)
        }
        let remaining = expiresAt.timeIntervalSince(now)
        let closingWindow = cache.ttl == extendedTTL ? extendedClosingWindow : defaultClosingWindow
        return CacheLifeSegment(
            text: "cache " + remainingText(remaining),
            state: remaining < closingWindow ? .closing : .warm
        )
    }

    /// `47m` in whole minutes rounded down, or `40s` under a minute in whole seconds
    /// rounded down but never `0s`: the cache is still warm, and "0s" would read as
    /// gone. Formatted from the Double: an `expires_at` from a garbled payload can be
    /// any finite number, and `Int(_:)` past `Int.max` would trap the whole line.
    nonisolated static func remainingText(_ remaining: TimeInterval) -> String {
        if remaining >= 60 {
            return String(format: "%.0fm", (remaining / 60).rounded(.down))
        }
        return String(format: "%.0fs", max(1, remaining.rounded(.down)))
    }

    /// Dim throughout, like the rest of the line: plain dim while warm, the context
    /// bar's dim yellow while closing, its dim red once cold.
    nonisolated static func colour(for state: CacheLifeState) -> String {
        switch state {
        case .warm: StatusLineText.ANSI.percent
        case .closing: StatusLineText.ANSI.filling
        case .expired: StatusLineText.ANSI.tight
        }
    }
}
