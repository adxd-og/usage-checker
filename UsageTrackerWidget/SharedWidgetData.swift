import Foundation

/// One model-specific weekly window ("Opus only", "Fable only", …) as shown by the widget.
struct WidgetBucket: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let percent: Double
}

/// Shared between the main app (writer) and the widget extension (reader).
/// Stored in the App Group container so both processes can access it.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    let fiveHourPercent: Double?
    let fiveHourResetsAt: Date?
    let sevenDayPercent: Double?
    let sevenDayResetsAt: Date?
    /// Optional because a snapshot file written by an older build doesn't have it.
    let modelBuckets: [WidgetBucket]?
    let plan: String?
    let updatedAt: Date

    var weeklyModelBuckets: [WidgetBucket] { modelBuckets ?? [] }

    static let placeholder = WidgetSnapshot(
        fiveHourPercent: 42,
        fiveHourResetsAt: Date().addingTimeInterval(2 * 3600 + 17 * 60),
        sevenDayPercent: 18,
        sevenDayResetsAt: Date().addingTimeInterval(2 * 24 * 3600 + 22 * 3600),
        modelBuckets: [
            WidgetBucket(id: "seven_day_fable", label: "Fable only", percent: 24),
            WidgetBucket(id: "seven_day_opus", label: "Opus only", percent: 12),
        ],
        plan: "Max 5x",
        updatedAt: Date()
    )

    var headlinePercent: Double {
        let fixed = [fiveHourPercent, sevenDayPercent].compactMap { $0 }
        return (fixed + weeklyModelBuckets.map(\.percent)).max() ?? 0
    }

    var headlineLabel: String {
        guard let f = fiveHourPercent else { return "—" }
        return "\(Int(f.rounded()))%"
    }
}

enum SharedWidgetStore {
    static let appGroupID = "group.com.usagetracker.app"
    static let widgetKind = "UsageTrackerWidget"
    private static let fileName = "widget-snapshot.json"

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
