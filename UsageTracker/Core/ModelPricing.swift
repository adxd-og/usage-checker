import Foundation

struct ModelPrice: Sendable {
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

    static func price(for model: String) -> ModelPrice {
        let normalized = normalize(model)
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

    /// Strips the parts of a model id that don't affect pricing: the date suffix
    /// ("claude-haiku-4-5-20251001") and the context-size tag ("claude-fable-5[1m]" —
    /// long context bills at standard rates).
    static func normalize(_ model: String) -> String {
        var s = model.lowercased()
        if let bracket = s.firstIndex(of: "[") { s = String(s[..<bracket]) }
        if let m = dateSuffixRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range, in: s) {
            s.removeSubrange(r)
        }
        return s
    }

    /// Returns nil for synthetic / internal model identifiers we don't want to surface.
    static func displayName(for model: String) -> String? {
        if isSynthetic(model) { return nil }

        // "claude-<family>-<major>[-<minor>]" → "Family Major[.Minor]". Parsing the id
        // instead of keeping a per-model list means a brand-new family (like Fable)
        // labels itself correctly with no edit here.
        if let parsed = parseID(model.lowercased()) {
            return parsed.version.map { "\(parsed.family) \($0)" } ?? parsed.family
        }

        // Ids without the canonical prefix (bare "opus", legacy "claude-3-5-sonnet-…"):
        // at least recognize the family word.
        let l = model.lowercased()
        for family in ["fable", "mythos", "opus", "sonnet", "haiku"] where l.contains(family) {
            return family.capitalized
        }
        return model
    }

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
        return "other"
    }
}
