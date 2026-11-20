import Foundation

/// models.dev's `mistral` family, the one table the vibe CLI's sessions are priced from (spec
/// 2026-11-10 Mistral provider § Local usage (P2), Model and price; plan R5). Kept apart from
/// `ModelPricing`'s table of the other four families: Mistral resells models other families list
/// (the GLM line, `deepseek-v4-1-flash-1017`), and one table filled family by family gives a
/// shared id the last family's rate for every CLI. Here vibe's ids never meet another family's
/// rows and the other CLIs never meet Mistral's. Filled by `ModelsDevRefresher` from its cache at
/// launch and from models.dev once a day; no hardcoded row.
enum MistralModelPricing {
    /// One model of the family.
    struct Model: Codable, Equatable, Sendable {
        /// Base rates as `ModelsDevPricing.price(provider:id:model:)` reads them; nil when
        /// models.dev lists none (a speech model) or a rate nobody would charge.
        var price: ModelPrice?
        /// models.dev's display name ("Mistral Medium 3.5"): what vibe's aliases are matched
        /// against when they are no key, and, once cleaned (`usableName`), the name the model is
        /// shown under (`displayName(activeModel:modelName:)`).
        var name: String?
    }

    nonisolated(unsafe) private static var table: [String: Model] = [:]
    private static let lock = NSLock()

    /// The family as models.dev last answered, by normalised id. A test sets its own and clears
    /// it in `tearDown`.
    static func update(_ models: [String: Model]) {
        lock.lock()
        defer { lock.unlock() }
        table = models
    }

    static var current: [String: Model] {
        lock.lock()
        defer { lock.unlock() }
        return table
    }
}

extension MistralModelPricing {
    /// The family's rate for a vibe session (spec § Model and price; plan R5): `active_model`,
    /// then the id vibe sent (`model_name`), first as exact keys, then by models.dev's display
    /// names in the id's spelling (vibe's default alias `mistral-medium-3.5` is "Mistral Medium
    /// 3.5", `mistral-medium-2604`), then by the app's shorter-line rule (`mistral-large-4-0-3`
    /// → `mistral-large-4`). Exact keys come first, so a bare `glm-5` row never outranks the
    /// `zai-glm-5-3` vibe sent. nil when nothing matches: tokens without dollars.
    static func price(activeModel: String?, modelName: String?) -> ModelPrice? {
        let ids = [activeModel, modelName].compactMap { $0 }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        let models = current
        for id in ids {
            if let rate = models[ModelPricing.normalize(id)]?.price { return rate }
        }
        for id in ids {
            if let rate = namePrice(id, in: models) { return rate }
        }
        for id in ids {
            if let rate = linePrice(id, in: models) { return rate }
        }
        return nil
    }

    /// "Mistral Medium 3.5" → "mistral-medium-3.5": lowercased; every run of characters that
    /// are not letters, digits or dots becomes one hyphen, none at either end. Applied to a
    /// display name and to the id it is matched with alike.
    static func nameKey(_ text: String) -> String {
        var key = ""
        var gap = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." {
                if gap && !key.isEmpty { key.append("-") }
                gap = false
                key.unicodeScalars.append(scalar)
            } else {
                gap = true
            }
        }
        return key
    }

    /// The rate of the models whose display name reads as `id`. nil when none does, when one
    /// of them has no rate, or when their rates differ: two models sharing a name at two rates
    /// cannot say which one ran, and a wrong rate is worse than none.
    static func namePrice(_ id: String, in models: [String: Model]) -> ModelPrice? {
        let wanted = nameKey(id)
        guard !wanted.isEmpty else { return nil }
        let matches = models.values.filter { $0.name.map(nameKey) == wanted }
        guard let first = matches.first?.price,
              matches.allSatisfy({ $0.price == first })
        else { return nil }
        return first
    }

    /// models.dev's name for a vibe session's model (spec 2026-11-19 Mistral model names § Rule),
    /// looked up in the order its price is (`price(activeModel:modelName:)`): `active_model`, then
    /// `model_name`, as exact keys; then a display name that reads as the id, as models.dev spells
    /// it; then the shorter line. A row without a usable name (`usableName`) is passed over and the
    /// lookup goes on. nil when no row names the model, an empty table included: the row then reads
    /// as `ModelPricing.displayName` names it.
    static func displayName(activeModel: String?, modelName: String?) -> String? {
        let ids = [activeModel, modelName].compactMap { $0 }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        let models = current
        for id in ids {
            if let name = models[ModelPricing.normalize(id)]?.name.flatMap(usableName) { return name }
        }
        for id in ids {
            if let name = nameReadAs(id, in: models) { return name }
        }
        for id in ids {
            if let name = lineName(id, in: models) { return name }
        }
        return nil
    }

    /// The display name that reads as `id` (`nameKey`), as models.dev spells it: the first usable
    /// one by row id. Unlike `namePrice`, rows sharing the name at two rates still give it: which
    /// one ran is unknown, but it has that name either way.
    static func nameReadAs(_ id: String, in models: [String: Model]) -> String? {
        let wanted = nameKey(id)
        guard !wanted.isEmpty else { return nil }
        return models
            .filter { $0.value.name.map(nameKey) == wanted }
            .sorted { $0.key < $1.key }
            .lazy
            .compactMap { $0.value.name.flatMap(usableName) }
            .first
    }

    /// `linePrice`'s walk, for a name: the id less one `-` or `.` part at a time, three times at
    /// most; the first of those rows with a usable name.
    static func lineName(_ id: String, in models: [String: Model]) -> String? {
        var candidate = ModelPricing.normalize(id)
        for _ in 0..<3 {
            if let dash = candidate.lastIndex(of: "-") {
                candidate = String(candidate[..<dash])
            } else if let dot = candidate.lastIndex(of: ".") {
                candidate = String(candidate[..<dot])
            } else {
                return nil
            }
            if let name = models[candidate]?.name.flatMap(usableName) { return name }
        }
        return nil
    }

    /// The longest name shown, in characters, once cleaned (spec § Untrusted names).
    static let longestName = 64

    /// A name from models.dev as the app may show it: a server's string, so without control
    /// characters (`MistralCopy.withoutControlCharacters`: `brioche status` prints names raw) and
    /// trimmed. nil when nothing is left or more than `longestName` characters are.
    static func usableName(_ raw: String) -> String? {
        let name = MistralCopy.withoutControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= longestName else { return nil }
        return name
    }

    /// `ModelPricing.dynamicLookup`'s suffix rule over this family only: the id less one `-` or
    /// `.` part at a time, three times at most.
    static func linePrice(_ id: String, in models: [String: Model]) -> ModelPrice? {
        var candidate = ModelPricing.normalize(id)
        for _ in 0..<3 {
            if let dash = candidate.lastIndex(of: "-") {
                candidate = String(candidate[..<dash])
            } else if let dot = candidate.lastIndex(of: ".") {
                candidate = String(candidate[..<dot])
            } else {
                return nil
            }
            if let rate = models[candidate]?.price { return rate }
        }
        return nil
    }
}
