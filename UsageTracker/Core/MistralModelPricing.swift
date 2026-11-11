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
        /// models.dev lists none (a speech model).
        var price: ModelPrice?
        /// models.dev's display name ("Mistral Medium 3.5"): what vibe's aliases are matched
        /// against when they are no key.
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
