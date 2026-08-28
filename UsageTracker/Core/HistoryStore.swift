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
    /// Absent in every record written before history went multi-provider, and back
    /// then only Claude was ever recorded — so a missing field means "claude".
    private let storedServiceID: String?

    var serviceID: String { storedServiceID ?? "claude" }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, plan, bucketPercents
        case fiveHourPercent, fiveHourResetsAt
        case sevenDayPercent, sevenDayResetsAt
        case opusWeeklyPercent, sonnetWeeklyPercent
        case claudeDesignWeeklyPercent, coworkWeeklyPercent
        case extraCreditsUsed
        case storedServiceID = "serviceID"
    }

    init(from snapshot: ServiceSnapshot, at date: Date = Date()) {
        self.id = UUID()
        self.timestamp = date
        self.plan = snapshot.plan
        self.storedServiceID = snapshot.id

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

    /// Append-only JSONL log: one record per line. A poll appends ~300 bytes
    /// instead of re-serializing the whole array (which rewrote megabytes to
    /// disk every minute once the history grew).
    private let fileURL: URL
    /// Pre-JSONL builds stored a single JSON array here; migrated on first load.
    private let legacyURL: URL
    private var records: [HistoryRecord] = []
    private var loaded = false
    private let maxAge: TimeInterval = 90 * 24 * 3600
    private let minIntervalBetweenSnapshots: TimeInterval = 30
    /// Records rotated out of memory but still sitting in the on-disk log;
    /// the file is compacted once enough of them pile up.
    private var staleOnDisk = 0
    private let compactionThreshold = 5000

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Not private: it is the default argument of an internal initializer, and a
    /// default argument may not reference a private member.
    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("UsageTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Injectable log location — the tests point it at a temp directory instead of
    /// the real Application Support log.
    init(directory: URL = HistoryStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("history.jsonl")
        self.legacyURL = directory.appendingPathComponent("history.json")
    }

    func append(snapshot: ServiceSnapshot) {
        loadIfNeeded()
        let now = Date()
        // Throttle per service, not globally: with several providers polling
        // together, a single `records.last` check let the first one through and
        // silently dropped every other provider's point.
        if let last = records.last(where: { $0.serviceID == snapshot.id }),
           now.timeIntervalSince(last.timestamp) < minIntervalBetweenSnapshots {
            return
        }
        let record = HistoryRecord(from: snapshot, at: now)
        records.append(record)
        rotateIfNeeded()
        if staleOnDisk >= compactionThreshold {
            rewriteFile()
        } else {
            appendLine(record)
        }
    }

    func all(service: String = "claude") -> [HistoryRecord] {
        loadIfNeeded()
        return records.filter { $0.serviceID == service }
    }

    func records(since cutoff: Date, service: String = "claude") -> [HistoryRecord] {
        loadIfNeeded()
        return records.filter { $0.timestamp >= cutoff && $0.serviceID == service }
    }

    /// Recent records for every service at once, keyed by service id. One pass over the
    /// log instead of one per provider: the popover needs a burn rate for each tab, and
    /// asking `records(since:service:)` per provider re-scanned the whole array every
    /// time.
    func recentByService(since cutoff: Date) -> [String: [HistoryRecord]] {
        loadIfNeeded()
        var out: [String: [HistoryRecord]] = [:]
        for record in records where record.timestamp >= cutoff {
            out[record.serviceID, default: []].append(record)
        }
        return out
    }

    /// Service ids that have actually recorded something — what the dashboard's
    /// provider picker offers.
    func recordedServices() -> [String] {
        loadIfNeeded()
        return Set(records.map(\.serviceID)).sorted()
    }

    func purgeAll() {
        records = []
        staleOnDisk = 0
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyURL)
        loaded = true
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }

        var parsed: [HistoryRecord] = []
        var corrupt = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(HistoryRecord.self, from: Data(line)) {
                parsed.append(record)
            } else {
                corrupt += 1
            }
        }
        if parsed.isEmpty && corrupt > 0 {
            // Nothing decodable — start fresh, keep a backup
            let backup = fileURL.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            records = []
            return
        }
        records = parsed
        rotateIfNeeded()
        if staleOnDisk > 0 || corrupt > 0 {
            rewriteFile()
        }
    }

    /// One-time conversion of the pre-JSONL array file. The legacy file is
    /// removed only after the JSONL log is safely on disk. A legacy file that is
    /// NEWER than an existing log means a pre-JSONL build ran after the
    /// migration (rollback) — it always rewrites the complete array, so it
    /// supersedes the log and migration runs again.
    private func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        if fm.fileExists(atPath: fileURL.path) {
            let legacyModified = (try? legacyURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let logModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantFuture
            guard legacyModified > logModified else { return }
        }
        guard let data = try? Data(contentsOf: legacyURL) else { return }
        guard let legacy = try? decoder.decode([HistoryRecord].self, from: data) else {
            let backup = legacyURL.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: legacyURL, to: backup)
            return
        }
        records = legacy
        rewriteFile()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        records = []
    }

    private func rotateIfNeeded() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = records.count
        records.removeAll { $0.timestamp < cutoff }
        staleOnDisk += before - records.count
    }

    private func appendLine(_ record: HistoryRecord) {
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: [.atomic])
            }
        } catch {
            NSLog("[UT] HistoryStore append failed: %@", String(describing: error))
        }
    }

    /// Full rewrite — only at load-time cleanup and when rotation has left
    /// enough dead records in the log (about once every few days), never on
    /// the per-poll path.
    private func rewriteFile() {
        var data = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            staleOnDisk = 0
        } catch {
            NSLog("[UT] HistoryStore compaction failed: %@", String(describing: error))
        }
    }
}
