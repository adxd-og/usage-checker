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
}

/// One provider ("Claude", "Codex", …) with its usage windows.
struct WidgetService: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let plan: String?
    let buckets: [WidgetBucket]

    /// The window the small widget's ring shows: the session window when the
    /// provider has one, otherwise whichever window is closest to its limit.
    var headlineBucket: WidgetBucket? {
        buckets.first(where: \.isSession) ?? buckets.max(by: { $0.percent < $1.percent })
    }

    var sessionBuckets: [WidgetBucket] { buckets.filter(\.isSession) }
    var nonSessionBuckets: [WidgetBucket] { buckets.filter { !$0.isSession } }
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
