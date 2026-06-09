import Foundation

/// A single point-in-time observation of subscription usage. Stored to disk for trends and charts.
struct HistoryRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let fiveHourPercent: Double?
    let fiveHourResetsAt: Date?
    let sevenDayPercent: Double?
    let sevenDayResetsAt: Date?
    let opusWeeklyPercent: Double?
    let sonnetWeeklyPercent: Double?
    let claudeDesignWeeklyPercent: Double?
    let coworkWeeklyPercent: Double?
    let extraCreditsUsed: Double?
    let plan: String?
    /// Every bucket's utilization keyed by bucket id. Optional because records written
    /// by older builds don't have it; those fall back to the fixed fields above.
    let bucketPercents: [String: Double]?

    init(from snapshot: ServiceSnapshot, at date: Date = Date()) {
        self.id = UUID()
        self.timestamp = date
        self.plan = snapshot.plan

        func bucket(_ id: String) -> UsageBucket? {
            snapshot.buckets.first(where: { $0.id == id })
        }

        self.fiveHourPercent = bucket("five_hour")?.utilization
        self.fiveHourResetsAt = bucket("five_hour")?.resetsAt
        self.sevenDayPercent = bucket("seven_day")?.utilization
        self.sevenDayResetsAt = bucket("seven_day")?.resetsAt
        self.opusWeeklyPercent = bucket("seven_day_opus")?.utilization
        self.sonnetWeeklyPercent = bucket("seven_day_sonnet")?.utilization
        self.claudeDesignWeeklyPercent = bucket("seven_day_omelette")?.utilization
        self.coworkWeeklyPercent = bucket("seven_day_cowork")?.utilization
        self.extraCreditsUsed = snapshot.extraUsage?.usedCredits
        self.bucketPercents = Dictionary(
            snapshot.buckets.map { ($0.id, $0.utilization) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func percent(for bucketId: String) -> Double? {
        if let p = bucketPercents?[bucketId] { return p }
        switch bucketId {
        case "five_hour": return fiveHourPercent
        case "seven_day": return sevenDayPercent
        case "seven_day_opus": return opusWeeklyPercent
        case "seven_day_sonnet": return sonnetWeeklyPercent
        case "seven_day_omelette": return claudeDesignWeeklyPercent
        case "seven_day_cowork": return coworkWeeklyPercent
        default: return nil
        }
    }
}

actor HistoryStore {
    static let shared = HistoryStore()

    private let fileURL: URL
    private var records: [HistoryRecord] = []
    private var loaded = false
    private let maxAge: TimeInterval = 90 * 24 * 3600
    private let minIntervalBetweenSnapshots: TimeInterval = 30

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("UsageTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")
    }

    func append(snapshot: ServiceSnapshot) {
        loadIfNeeded()
        let now = Date()
        if let last = records.last, now.timeIntervalSince(last.timestamp) < minIntervalBetweenSnapshots {
            return
        }
        records.append(HistoryRecord(from: snapshot, at: now))
        rotateIfNeeded()
        persist()
    }

    func all() -> [HistoryRecord] {
        loadIfNeeded()
        return records
    }

    func records(since cutoff: Date) -> [HistoryRecord] {
        loadIfNeeded()
        return records.filter { $0.timestamp >= cutoff }
    }

    func records(in interval: DateInterval) -> [HistoryRecord] {
        loadIfNeeded()
        return records.filter { interval.contains($0.timestamp) }
    }

    func mostRecent(_ n: Int) -> [HistoryRecord] {
        loadIfNeeded()
        return Array(records.suffix(n))
    }

    func purgeAll() {
        records = []
        try? FileManager.default.removeItem(at: fileURL)
        loaded = true
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([HistoryRecord].self, from: data)
        } catch {
            // Corrupt file — start fresh, keep a backup
            let backup = fileURL.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            records = []
        }
    }

    private func rotateIfNeeded() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = records.count
        records.removeAll { $0.timestamp < cutoff }
        if before != records.count {
            // rotation happened, fine
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[UT] HistoryStore persist failed: %@", String(describing: error))
        }
    }
}
