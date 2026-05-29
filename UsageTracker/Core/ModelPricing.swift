import Foundation

struct ModelPrice: Sendable {
    let inputPerM: Double
    let outputPerM: Double
    let cacheReadPerM: Double
    let cacheCreate5mPerM: Double
    let cacheCreate1hPerM: Double
}

enum ModelPricing {
    static let table: [String: ModelPrice] = [
        "claude-opus-4-8": ModelPrice(inputPerM: 15, outputPerM: 75, cacheReadPerM: 1.5, cacheCreate5mPerM: 18.75, cacheCreate1hPerM: 30),
        "claude-opus-4-7": ModelPrice(inputPerM: 15, outputPerM: 75, cacheReadPerM: 1.5, cacheCreate5mPerM: 18.75, cacheCreate1hPerM: 30),
        "claude-opus-4-6": ModelPrice(inputPerM: 15, outputPerM: 75, cacheReadPerM: 1.5, cacheCreate5mPerM: 18.75, cacheCreate1hPerM: 30),
        "claude-sonnet-4-6": ModelPrice(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6),
        "claude-sonnet-4-5": ModelPrice(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6),
        "claude-haiku-4-5": ModelPrice(inputPerM: 1, outputPerM: 5, cacheReadPerM: 0.1, cacheCreate5mPerM: 1.25, cacheCreate1hPerM: 2),
    ]

    static let fallback = ModelPrice(inputPerM: 3, outputPerM: 15, cacheReadPerM: 0.3, cacheCreate5mPerM: 3.75, cacheCreate1hPerM: 6)

    static func price(for model: String) -> ModelPrice {
        if let exact = table[model] { return exact }
        let lower = model.lowercased()
        if lower.contains("opus") { return table["claude-opus-4-8"]! }
        if lower.contains("haiku") { return table["claude-haiku-4-5"]! }
        if lower.contains("sonnet") { return table["claude-sonnet-4-6"]! }
        return fallback
    }

    /// Returns nil for synthetic / internal model identifiers we don't want to surface.
    static func displayName(for model: String) -> String? {
        // Internal / synthetic markers shouldn't show up in the UI as if they were real models.
        if isSynthetic(model) { return nil }

        let l = model.lowercased()
        let family: String?
        if l.contains("opus") { family = "Opus" }
        else if l.contains("sonnet") { family = "Sonnet" }
        else if l.contains("haiku") { family = "Haiku" }
        else { family = nil }

        guard let family else { return model }
        // Derive "major.minor" from the ID so a brand-new model labels itself correctly
        // without anyone having to edit this file. e.g. claude-opus-4-8 → "Opus 4.8".
        if let version = versionString(from: l) { return "\(family) \(version)" }
        return family
    }

    /// Pulls the version that immediately follows the family word in a model ID
    /// (e.g. "claude-opus-4-8-20260520" → "4.8"). nil when there's no such version.
    private static func versionString(from lowerID: String) -> String? {
        let range = NSRange(lowerID.startIndex..., in: lowerID)
        guard let m = versionRegex.firstMatch(in: lowerID, range: range),
              let majorR = Range(m.range(at: 1), in: lowerID),
              let minorR = Range(m.range(at: 2), in: lowerID)
        else { return nil }
        return "\(lowerID[majorR]).\(lowerID[minorR])"
    }

    private static let versionRegex = try! NSRegularExpression(
        pattern: #"(?:opus|sonnet|haiku)-(\d+)-(\d+)"#
    )

    static func isSynthetic(_ model: String) -> Bool {
        model.isEmpty
            || model == "unknown"
            || model.hasPrefix("<")
            || model.contains("synthetic")
    }

    static func family(for model: String) -> String {
        let l = model.lowercased()
        if l.contains("opus") { return "opus" }
        if l.contains("sonnet") { return "sonnet" }
        if l.contains("haiku") { return "haiku" }
        return "other"
    }
}
