import Foundation

/// Where a stretch of a chat began (spec 2026-10-16 limit analytics § The tab, item 5).
enum StretchOpening: Equatable, Sendable {
    /// The chat's first turn in the window.
    case firstTurn
    /// A compaction of the chat's context.
    case compaction
    /// A cold start: the context rebuilt from nothing because the cache had expired.
    case coldStart
}

/// One stretch of a chat inside a window: from where it began to the next compaction or
/// cold start (spec § The tab, item 5).
struct ChatStretch: Equatable, Sendable {
    let opening: StretchOpening
    /// Its first and last turn, sub-agents' included.
    let firstAt: Date
    let lastAt: Date
    /// Percent points of the window: what the bin rule gave the chat in the stretch's half
    /// hours (spec § The rule).
    let points: Double
    /// API-list dollars of its turns, sub-agents' included.
    let cost: Double
    /// What rebuilding the context cost in it: the fresh input and cache write of its
    /// cold-start turns, at API-list prices.
    let coldStartCost: Double
    /// The first prompt typed for it, collapsed and cut like a chat's name; nil when none
    /// was.
    let prompt: String?
}

extension LimitShareRules {
    /// A cold start reads under this share of its prompt from cache.
    static let coldReadShare = 0.05
    /// A cold start rebuilds at least this many tokens: Claude's cache write, Codex's
    /// whole prompt.
    static let coldContextTokens = 10_000
    /// A stretch shorter than this, from its beginning to the next one's, merges into the
    /// next, so a 5-minute cache does not cut a task at every pause.
    static let shortestStretch: TimeInterval = 10 * 60
    /// How long before a stretch's first main-thread turn its opening prompt may have been
    /// typed, when the log holds no earlier main-thread turn of the chat to bound it: a
    /// first answer can take many minutes.
    static let promptLead: TimeInterval = 60 * 60

    /// Whether `turn` rebuilt its chat's context from nothing (spec § The tab, item 5): a
    /// main-thread turn reading under 5 % of its prompt (fresh input, cache read and cache
    /// write) from cache, and
    /// - on Claude, writing at least 10,000 tokens of cache: the cache the chat chose (5
    ///   minutes or an hour) had expired;
    /// - on Codex, which logs no cache write, on a prompt of at least 10,000 tokens.
    nonisolated static func isColdStart(_ turn: TurnCost, serviceID: String) -> Bool {
        guard turn.isMainThread else { return false }
        let tokens = turn.tokens
        let prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite
        guard prompt > 0, Double(tokens.cacheRead) < coldReadShare * Double(prompt) else { return false }
        if serviceID == "codex" { return prompt >= coldContextTokens }
        return tokens.cacheWrite >= coldContextTokens
    }

    /// What `turn`'s rebuild cost: its fresh input and its cache write, in dollars.
    nonisolated static func rebuildCost(_ turn: TurnCost) -> Double {
        (turn.tokens.cost?.input ?? 0) + (turn.tokens.cost?.cacheWrite ?? 0)
    }

    /// Every chat of `share`, cut into its stretches in the share's window, oldest first,
    /// by chat id (spec § The tab, item 5).
    ///
    /// A stretch begins at the chat's first turn in the window, at a compaction of its
    /// context, or at a cold start (`isColdStart`). One shorter than `shortestStretch` up
    /// to the next beginning merges into the next one. A turn belongs to the stretch it ran
    /// in, sub-agents' turns included.
    ///
    /// A stretch's points are what the bin rule gave the chat in its half hours (spec § The
    /// rule): a half hour's points for the chat are split between its stretches the way
    /// the rule split the half hour, by the chat's dollars there, then tokens, then evenly;
    /// a half hour the percent reached late, with no turn of the chat, takes the split of
    /// the half hour before it.
    ///
    /// A stretch's name is the first prompt typed for it: for one a compaction began, the
    /// first after the compaction; for any other, the first after the chat's previous
    /// main-thread turn in the log, a sub-agent's turns aside, or, with no such turn, the
    /// first within `promptLead` before the stretch's first main-thread turn. Never one
    /// typed after the stretch's last turn.
    nonisolated static func stretches(
        of share: LimitShare, log: TurnCostLog, serviceID: String
    ) -> [String: [ChatStretch]] {
        var turnsByChat: [String: [TurnCost]] = [:]
        var mainTimesByChat: [String: [Date]] = [:]
        for turn in log.turns {
            if turn.isMainThread { mainTimesByChat[turn.chatID, default: []].append(turn.timestamp) }
            if share.window.containsTurn(at: turn.timestamp) { turnsByChat[turn.chatID, default: []].append(turn) }
        }
        var out: [String: [ChatStretch]] = [:]
        for chat in share.chats {
            guard let turns = turnsByChat[chat.id], !turns.isEmpty else { continue }
            out[chat.id] = stretches(
                chatID: chat.id,
                turns: turns.sorted { $0.timestamp < $1.timestamp },
                share: share,
                compactions: log.compactions[chat.id] ?? [],
                prompts: log.prompts[chat.id] ?? [],
                mainTimes: (mainTimesByChat[chat.id] ?? []).sorted(),
                serviceID: serviceID
            )
        }
        return out
    }

    /// One chat's stretches from its turns in the share's window, which are in time order.
    private static func stretches(
        chatID: String,
        turns: [TurnCost],
        share: LimitShare,
        compactions: [Date],
        prompts: [ChatPrompt],
        mainTimes: [Date],
        serviceID: String
    ) -> [ChatStretch] {
        let window = share.window
        let firstAt = turns[0].timestamp
        var candidates: [(at: Date, opening: StretchOpening)] = compactions
            .filter { $0 > firstAt && $0 < window.end }
            .map { (at: $0, opening: StretchOpening.compaction) }
        candidates += turns
            .filter { $0.timestamp > firstAt && isColdStart($0, serviceID: serviceID) }
            .map { (at: $0.timestamp, opening: StretchOpening.coldStart) }
        candidates.sort { $0.at < $1.at }

        // A stretch shorter than `shortestStretch` merges into the next one: the next
        // one's beginning is dropped.
        var starts: [(at: Date, opening: StretchOpening)] = [(at: firstAt, opening: .firstTurn)]
        for candidate in candidates
        where candidate.at.timeIntervalSince(starts[starts.count - 1].at) >= shortestStretch {
            starts.append(candidate)
        }

        // A turn belongs to the stretch it ran in: from that stretch's beginning up to, not
        // including, the next one's.
        var groups = [[TurnCost]](repeating: [], count: starts.count)
        var current = 0
        for turn in turns {
            while current + 1 < starts.count, turn.timestamp >= starts[current + 1].at { current += 1 }
            groups[current].append(turn)
        }

        // The bin rule's points for this chat, half hour by half hour.
        var points = [Double](repeating: 0, count: starts.count)
        let binCount = share.bins.count
        if binCount > 0 {
            var use = [[Int: StretchUse]](repeating: [:], count: binCount)
            for (index, group) in groups.enumerated() {
                for turn in group {
                    use[binIndex(of: turn.timestamp, in: window, binCount: binCount)][index, default: StretchUse()]
                        .add(turn)
                }
            }
            for (bin, binShare) in share.bins.enumerated() {
                guard let given = binShare.chats[chatID], given > 0 else { continue }
                let source = !use[bin].isEmpty ? use[bin] : (bin > 0 ? use[bin - 1] : [:])
                for (index, part) in split(given, among: source) { points[index] += part }
            }
        }

        var out: [ChatStretch] = []
        for (index, (start, group)) in zip(starts, groups).enumerated() where !group.isEmpty {
            let lastAt = group[group.count - 1].timestamp
            let firstMain = group.first(where: \.isMainThread)?.timestamp ?? group[0].timestamp
            let opener: ChatPrompt?
            switch start.opening {
            case .compaction:
                opener = prompts.first { $0.at >= start.at && $0.at <= lastAt }
            case .firstTurn, .coldStart:
                if let previous = mainTimes.last(where: { $0 < firstMain }) {
                    opener = prompts.first { $0.at > previous && $0.at <= lastAt }
                } else {
                    let earliest = firstMain.addingTimeInterval(-promptLead)
                    opener = prompts.first { $0.at >= earliest && $0.at <= lastAt }
                }
            }
            out.append(ChatStretch(
                opening: start.opening,
                firstAt: group[0].timestamp,
                lastAt: lastAt,
                points: points[index],
                cost: group.reduce(0) { $0 + $1.cost },
                coldStartCost: group
                    .filter { isColdStart($0, serviceID: serviceID) }
                    .reduce(0) { $0 + rebuildCost($1) },
                prompt: opener?.text
            ))
        }
        return out
    }

    /// What one stretch of a chat spent in one half hour.
    private struct StretchUse {
        var cost = 0.0
        var tokens = 0

        mutating func add(_ turn: TurnCost) {
            cost += turn.cost
            tokens = TokenBreakdown.saturating(tokens, turn.tokens.total)
        }
    }

    /// `points` split between stretches the way the bin rule splits a half hour between
    /// chats: by dollars; by tokens when it has no dollars; evenly when it has neither.
    private static func split(_ points: Double, among use: [Int: StretchUse]) -> [Int: Double] {
        guard !use.isEmpty else { return [:] }
        let dollars = use.values.reduce(0) { $0 + $1.cost }
        if dollars > 0 { return use.mapValues { points * $0.cost / dollars } }
        let tokens = use.values.reduce(0) { $0 + $1.tokens }
        if tokens > 0 { return use.mapValues { points * Double($0.tokens) / Double(tokens) } }
        return use.mapValues { _ in points / Double(use.count) }
    }
}
