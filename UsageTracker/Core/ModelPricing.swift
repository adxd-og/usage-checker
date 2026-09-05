import Foundation

struct ModelPrice: Sendable, Codable {
    let inputPerM: Double
    let outputPerM: Double
    let cacheReadPerM: Double
    let cacheCreate5mPerM: Double
    let cacheCreate1hPerM: Double
}

enum ModelPricing {
    // Prices per claude.com/pricing. Opus 4.5+ is $5/$25; the old $15/$75 tier
    // only applies to the deprecated Opus 4 / 4.1.
    static let table: [String: ModelPrice] = [
        "claude-fable-5": ModelPrice(inputPerM: 10, outputPerM: 50, cacheReadPerM: 1, cacheCreate5mPerM: 12.5, cacheCreate1hPerM: 20),
        "claude-mythos-5": ModelPrice(inputPerM: 10, outputPerM: 50, cacheReadPerM: 1, cacheCreate5mPerM: 12.5, cacheCreate1hPerM: 20),
        "claude-opus-4-8": ModelPrice(inputPerM: 5, outputPerM: 25, cacheReadPerM: 0.5, cacheCreate5mPerM: 6.25, cacheCreate1hPerM: 10),
        "claude-opus-4-7": ModelPrice(inputPerM: 5, outputPerM: 25, cacheReadPerM: 0.5, cacheCreate5mPerM: 6.25, cacheCreate1hPerM: 10),
        "claude-opus-4-6": ModelPrice(inputPerM: 5, outputPerM: 25, cacheReadPerM: 0.5, cacheCreate5mPerM: 6.25, cacheCreate1hPerM: 10),
        "claude-opus-4-5": ModelPrice(inputPerM: 5, outputPerM: 25, cacheReadPerM: 0.5, cacheCreate5mPerM: 6.25, cacheCreate1hPerM: 10),
        "claude-opus-4-1": ModelPrice(inputPerM: 15, outputPerM: 75, cacheReadPerM: 1.5, cacheCreate5mPerM: 18.75, cacheCreate1hPerM: 30),
        "claude-opus-4": ModelPrice(inputPerM: 15, outputPerM: 75, cacheReadPerM: 1.5, cacheCreate5mPerM: 18.75, cacheCreate1hPerM: 30),
        "claude-sonnet-4-6": ModelPrice(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6),
        "claude-sonnet-4-5": ModelPrice(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6),
        "claude-haiku-4-5": ModelPrice(inputPerM: 1, outputPerM: 5, cacheReadPerM: 0.1, cacheCreate5mPerM: 1.25, cacheCreate1hPerM: 2),
    ]

    static let fallback = ModelPrice(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6)

    // MARK: Dynamic pricing (models.dev)

    /// Rates loaded from models.dev (see `ModelsDevPricing`). Preferred over the
    /// hardcoded table so a freshly launched model prices correctly with no code
    /// change; the static table remains the offline fallback. Keys are normalized.
    nonisolated(unsafe) private static var dynamicTable: [String: ModelPrice] = [:]
    private static let dynamicLock = NSLock()

    static func updateDynamic(_ prices: [String: ModelPrice]) {
        dynamicLock.lock()
        defer { dynamicLock.unlock() }
        dynamicTable = prices
    }

    private static func dynamicPrice(for normalized: String) -> ModelPrice? {
        dynamicLock.lock()
        defer { dynamicLock.unlock() }
        return dynamicTable[normalized]
    }

    /// models.dev lookup with progressive fallback for ids that carry variant
    /// suffixes ("gpt-5.6-luna" → "gpt-5.6" → "gpt-5"). No family/static fallback:
    /// callers that get nil should skip pricing rather than guess a wrong family.
    static func dynamicLookup(for model: String) -> ModelPrice? {
        var candidate = normalize(model)
        for _ in 0..<4 {
            if let price = dynamicPrice(for: candidate) { return price }
            if let dash = candidate.lastIndex(of: "-") {
                candidate = String(candidate[..<dash])
            } else if let dot = candidate.lastIndex(of: ".") {
                candidate = String(candidate[..<dot])
            } else {
                break
            }
        }
        return nil
    }

    static func price(for model: String) -> ModelPrice {
        let normalized = normalize(model)
        if let live = dynamicPrice(for: normalized) { return live }
        if let exact = table[normalized] { return exact }
        // Newest family member as the price fallback: deprecated models that priced
        // differently (Opus 4 / 4.1) are pinned in the table by their exact ids above.
        if normalized.contains("fable") { return table["claude-fable-5"]! }
        if normalized.contains("mythos") { return table["claude-mythos-5"]! }
        if normalized.contains("opus") { return table["claude-opus-4-8"]! }
        if normalized.contains("haiku") { return table["claude-haiku-4-5"]! }
        if normalized.contains("sonnet") { return table["claude-sonnet-4-6"]! }
        return fallback
    }

    // Both functions run a regex and sit on per-turn hot paths (cost aggregation
    // over tens of thousands of log lines), so results are memoized — the set of
    // distinct model ids is tiny. The count cap is insurance against garbage ids.
    nonisolated(unsafe) private static var normalizeCache: [String: String] = [:]
    nonisolated(unsafe) private static var displayNameCache: [String: String?] = [:]

    /// Strips the parts of a model id that don't affect pricing: the date suffix
    /// ("claude-haiku-4-5-20251001") and the context-size tag ("claude-fable-5[1m]" —
    /// long context bills at standard rates).
    static func normalize(_ model: String) -> String {
        dynamicLock.lock()
        if let cached = normalizeCache[model] {
            dynamicLock.unlock()
            return cached
        }
        dynamicLock.unlock()

        var s = model.lowercased()
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if let m = dateSuffixRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range, in: s) {
            s.removeSubrange(r)
        }

        dynamicLock.lock()
        if normalizeCache.count > 10_000 { normalizeCache.removeAll() }
        normalizeCache[model] = s
        dynamicLock.unlock()
        return s
    }

    /// Returns nil for synthetic / internal model identifiers we don't want to surface.
    static func displayName(for model: String) -> String? {
        dynamicLock.lock()
        if let cached = displayNameCache[model] {
            dynamicLock.unlock()
            return cached
        }
        dynamicLock.unlock()

        let name = computeDisplayName(for: model)

        dynamicLock.lock()
        if displayNameCache.count > 10_000 { displayNameCache.removeAll() }
        displayNameCache[model] = name
        dynamicLock.unlock()
        return name
    }

    private static func computeDisplayName(for model: String) -> String? {
        if isSynthetic(model) { return nil }

        // "claude-<family>-<major>[-<minor>]" → "Family Major[.Minor]". Parsing the id
        // instead of keeping a per-model list means a brand-new family (like Fable)
        // labels itself correctly with no edit here.
        if let parsed = parseID(model.lowercased()) {
            return parsed.version.map { "\(parsed.family) \($0)" } ?? parsed.family
        }

        let l = model.lowercased()
        // xAI ships the same model line under build variants ("grok-4.6-build");
        // the line is what a user recognizes, so that's what the UI shows.
        if let line = grokLine(l) {
            return "Grok " + line.dropFirst("grok-".count)
        }

        // Ids without the canonical prefix (bare "opus", legacy "claude-3-5-sonnet-…"):
        // at least recognize the family word.
        for family in ["fable", "mythos", "opus", "sonnet", "haiku"] where l.contains(family) {
            return family.capitalized
        }
        return prettifyID(model)
    }

    /// "grok-4.6-build" → "grok-4.6". nil for ids that don't carry a version right
    /// after the prefix ("grok-build-0.1", "grok-imagine-video").
    private static func grokLine(_ lowerID: String) -> String? {
        let range = NSRange(lowerID.startIndex..., in: lowerID)
        guard let m = grokIDRegex.firstMatch(in: lowerID, range: range),
              let majorR = Range(m.range(at: 1), in: lowerID)
        else { return nil }
        var line = "grok-\(lowerID[majorR])"
        if let minorR = Range(m.range(at: 2), in: lowerID) {
            line += ".\(lowerID[minorR])"
        }
        return line
    }

    /// "gpt-5.1-codex-max" → "gpt-5.1-codex", "gpt-4.1-mini" → "gpt-4.1", "gpt-4o-mini"
    /// → "gpt-4o", "o4-mini" → "o4". The version survives, along with the two things
    /// OpenAI names a *line* with rather than a tier — a letter attached to the version
    /// ("4o") and `codex` — while the size and tier words a line ships under ("-max",
    /// "-mini", "-latest") and any trailing date are noise in a per-line cost split.
    /// nil for ids without a version right after the prefix ("gpt-image-1").
    private static func openAILine(_ lowerID: String) -> String? {
        let range = NSRange(lowerID.startIndex..., in: lowerID)
        if let m = gptIDRegex.firstMatch(in: lowerID, range: range),
           let majorR = Range(m.range(at: 1), in: lowerID) {
            var line = "gpt-\(lowerID[majorR])"
            if let minorR = Range(m.range(at: 2), in: lowerID) {
                line += ".\(lowerID[minorR])"
            }
            if let letterR = Range(m.range(at: 3), in: lowerID) {
                line += lowerID[letterR]
            }
            if m.range(at: 4).location != NSNotFound { line += "-codex" }
            return line
        }
        guard let m = oSeriesIDRegex.firstMatch(in: lowerID, range: range),
              let majorR = Range(m.range(at: 1), in: lowerID)
        else { return nil }
        return "o\(lowerID[majorR])"
    }

    /// Last resort for an id from a provider we don't parse specially — a model that
    /// only models.dev knows about ("gemini-3.1-pro-preview") should still read like a
    /// name in the UI instead of appearing as a raw slug.
    private static func prettifyID(_ id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        let range = NSRange(base.startIndex..., in: base)
        let stripped = dateSuffixRegex.stringByReplacingMatches(in: base, range: range, withTemplate: "")
        let words = stripped
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { part -> String in
                let s = String(part)
                if let acronym = acronyms[s.lowercased()] { return acronym }
                guard let first = s.first, first.isLetter else { return s }
                return first.uppercased() + s.dropFirst()
            }
        return words.isEmpty ? id : words.joined(separator: " ")
    }

    private static let acronyms = ["gpt": "GPT", "tts": "TTS", "ai": "AI"]

    private static func parseID(_ lowerID: String) -> (family: String, version: String?)? {
        let range = NSRange(lowerID.startIndex..., in: lowerID)
        guard let m = idRegex.firstMatch(in: lowerID, range: range),
              let familyR = Range(m.range(at: 1), in: lowerID),
              let majorR = Range(m.range(at: 2), in: lowerID)
        else { return nil }
        let family = String(lowerID[familyR]).capitalized
        var version = String(lowerID[majorR])
        if let minorR = Range(m.range(at: 3), in: lowerID) {
            version += ".\(lowerID[minorR])"
        }
        return (family, version)
    }

    /// Version numbers are 1–2 digits; the lookahead keeps 8-digit date stamps from
    /// being read as versions ("claude-haiku-4-5-20251001" → 4.5, not 4.5.2025…).
    private static let idRegex = try! NSRegularExpression(
        pattern: #"claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?!\d)"#
    )

    private static let dateSuffixRegex = try! NSRegularExpression(pattern: #"-\d{8}$"#)

    /// Anchored at the start so only a version directly after the prefix counts:
    /// "grok-4.20-multi-agent-0309" is the 4.20 line, "grok-build-0.1" is not a line.
    private static let grokIDRegex = try! NSRegularExpression(
        pattern: #"^grok-(\d{1,2})(?:[.-](\d{1,2}))?(?![\d.])"#
    )

    /// Same shape as `grokIDRegex` — anchored, so only a version directly after the
    /// prefix counts — with two more things captured after the version: a letter glued
    /// straight onto the digits, and the `codex` specialization. That letter names a
    /// line rather than a tier ("gpt-4o" is a different model at a different price from
    /// "gpt-4"), which is why it isn't stripped the way "-mini" is. The lookahead is
    /// what keeps a date stamp out of the minor slot: "gpt-5-2026-01-01" has no
    /// two-digit run that isn't followed by another digit, so it stays the 5 line.
    private static let gptIDRegex = try! NSRegularExpression(
        pattern: #"^gpt-(\d{1,2})(?:[.-](\d{1,2}))?([a-z])?(?![\d.])(-codex)?"#
    )

    /// The reasoning series is a bare letter and a number: "o3-pro" → "o3".
    private static let oSeriesIDRegex = try! NSRegularExpression(
        pattern: #"^o(\d{1,2})(?![\d.])"#
    )

    static func isSynthetic(_ model: String) -> Bool {
        model.isEmpty
            || model == "unknown"
            || model.hasPrefix("<")
            || model.contains("synthetic")
    }

    static func family(for model: String) -> String {
        let l = model.lowercased()
        for family in ["fable", "mythos", "opus", "sonnet", "haiku"] where l.contains(family) {
            return family
        }
        // Grok's families are model lines, not code names: collapsing every variant of
        // 4.6 into one bucket keeps the per-family cost split readable across a point
        // release, the way "opus" does for Anthropic.
        if l.hasPrefix("grok") { return grokLine(l) ?? "grok" }
        // Same reasoning for OpenAI, whose ids are all line + tier: without this every
        // Codex turn lands in one "other" bucket and the per-family split says nothing.
        // `normalize` first, so a date-stamped or context-tagged id reads as its line.
        if let line = openAILine(normalize(model)) { return line }
        return "other"
    }
}
