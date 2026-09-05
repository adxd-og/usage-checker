import Foundation

/// One usage window of a service, as shown by the widget.
struct WidgetBucket: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let percent: Double
    /// nil when the provider reports no reset time (or it's unknown).
    var resetsAt: Date? = nil
    /// "session" / "weekly" / "modelSpecific" / "other" — mirrors BucketKind.rawValue.
    var kind: String? = nil

    var isSession: Bool { kind == "session" }
    /// Promo pools stay visible in rows but never drive the widget's headline ring.
    var isPromo: Bool { id.lowercased().contains("promo") || label.lowercased().contains("promo") }
}

/// One provider ("Claude", "Codex", …) with its usage windows.
struct WidgetService: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let plan: String?
    let buckets: [WidgetBucket]
    /// Pay-as-you-go accounts get no rate-limit windows at all — their whole story is
    /// a dollar figure. Optional (and defaulted) so a file written by an older build
    /// still decodes. nil for subscription accounts.
    var spendLabel: String? = nil
    /// The provider stopped reporting and these are its last known numbers, so the
    /// widget dims them like every other surface. A property default is not a
    /// *decoding* default for a non-optional field — the synthesized `init(from:)`
    /// would throw `keyNotFound` on a file an older build wrote — so the decoder
    /// below is what actually makes an old snapshot readable.
    var isRetained: Bool = false

    /// Spelled out rather than synthesized: the custom decoder below needs them, and
    /// pinning the names here means a renamed property can't silently orphan a key
    /// that is already on disk.
    enum CodingKeys: String, CodingKey {
        case id, name, icon, plan, buckets, spendLabel, isRetained
    }

    /// A provider with neither windows nor spend has nothing to draw.
    var hasContent: Bool { !buckets.isEmpty || spendLabel != nil }

    /// The window the small widget's ring shows: the session window when the
    /// provider has one, otherwise whichever non-promo window is closest to its
    /// limit (promo pools only lead when they're all there is).
    /// Model-scoped windows don't lead the ring either.
    var headlineBucket: WidgetBucket? {
        if let session = buckets.first(where: { $0.isSession && !$0.isPromo }) { return session }
        let core = buckets.filter { !$0.isPromo && $0.kind != "modelSpecific" }
        let real = core.isEmpty ? buckets.filter { !$0.isPromo } : core
        return (real.isEmpty ? buckets : real).max(by: { $0.percent < $1.percent })
    }

    var sessionBuckets: [WidgetBucket] { buckets.filter(\.isSession) }
    var nonSessionBuckets: [WidgetBucket] { buckets.filter { !$0.isSession } }
}

/// Reading a file an older build wrote. The widget extension and the app ship
/// together, but the shared file outlives both across an update: the extension can
/// be asked for a timeline before the new app has ever published, and the snapshot
/// it finds is whatever the previous version left there. Anything added to
/// `WidgetService` therefore has to decode as absent, not as a failure — one
/// `keyNotFound` empties every widget on the user's desktop.
///
/// The extension is deliberately in place of the property default: `var isRetained:
/// Bool = false` only supplies a value to the *memberwise* initializer, and the
/// synthesized `init(from:)` still calls `decode(Bool.self, forKey: .isRetained)`.
/// Declaring this in an extension rather than in the struct body keeps the
/// memberwise initializer that `WidgetBridge` builds services with.
extension WidgetService {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.icon = try c.decode(String.self, forKey: .icon)
        self.plan = try c.decodeIfPresent(String.self, forKey: .plan)
        self.buckets = try c.decodeIfPresent([WidgetBucket].self, forKey: .buckets) ?? []
        self.spendLabel = try c.decodeIfPresent(String.self, forKey: .spendLabel)
        self.isRetained = try c.decodeIfPresent(Bool.self, forKey: .isRetained) ?? false
    }
}

/// Shared between the main app (writer) and the widget extension (reader).
/// Stored in the App Group container so both processes can access it.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    let services: [WidgetService]
    let updatedAt: Date

    func service(id: String) -> WidgetService? {
        services.first(where: { $0.id == id })
    }

    static let placeholder = WidgetSnapshot(
        services: [
            WidgetService(
                id: "claude", name: "Claude", icon: "sparkles", plan: "Max 5x",
                buckets: [
                    WidgetBucket(id: "five_hour", label: "5h session", percent: 42,
                                 resetsAt: Date().addingTimeInterval(2 * 3600 + 17 * 60), kind: "session"),
                    WidgetBucket(id: "seven_day", label: "All models", percent: 18,
                                 resetsAt: Date().addingTimeInterval(2 * 24 * 3600), kind: "weekly"),
                    WidgetBucket(id: "seven_day_fable", label: "Fable only", percent: 24, kind: "modelSpecific"),
                ]
            ),
            WidgetService(
                id: "antigravity", name: "Antigravity", icon: "circle.grid.cross", plan: "Pro",
                buckets: [
                    WidgetBucket(id: "antigravity_gemini", label: "Gemini models", percent: 31,
                                 resetsAt: Date().addingTimeInterval(5 * 3600), kind: "weekly"),
                    WidgetBucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 12, kind: "weekly"),
                ]
            ),
        ],
        updatedAt: Date()
    )
}

enum SharedWidgetStore {
    static let appGroupID = "group.com.usagetracker.app"
    static let providerWidgetKind = "UsageTrackerWidget"
    static let allProvidersWidgetKind = "UsageTrackerAllProvidersWidget"
    /// v2: the multi-service shape. A file written by a pre-1.3 build has a
    /// different name, so stale single-service JSON can't half-decode.
    private static let fileName = "widget-snapshot-v2.json"

    private static var fileURL: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return container.appendingPathComponent(fileName)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Silent — widget will keep showing the last good snapshot
        }
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
