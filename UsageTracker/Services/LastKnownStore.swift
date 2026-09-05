import Foundation

/// One service's last successful reading. Kept so a provider that is closed —
/// or a whole relaunch — doesn't blank the numbers it reported an hour ago.
struct LastKnownService: Codable, Equatable, Sendable {
    let displayName: String
    let icon: String
    let plan: String?
    let accountLabel: String?
    let buckets: [UsageBucket]
    let extraUsage: ExtraUsage?
    let weekCost: Double?
    let fetchedAt: Date
    /// Position in the poll that stored it, so a seeded popover lists providers in
    /// the same order the first real poll will — tiles that jump on launch read as
    /// a bug even when the numbers are right.
    let order: Int

    init(from service: ServiceSnapshot, order: Int) {
        self.displayName = service.displayName
        self.icon = service.icon
        self.plan = service.plan
        self.accountLabel = service.accountLabel
        self.buckets = service.buckets
        self.extraUsage = service.extraUsage
        self.weekCost = service.weekCost
        self.fetchedAt = service.fetchedAt
        self.order = order
    }

    /// The throttle's comparison: the numbers only. `fetchedAt` moves on every
    /// poll and is not by itself a reason to rewrite the file.
    func hasSameValues(as other: LastKnownService) -> Bool {
        buckets == other.buckets
            && plan == other.plan
            && extraUsage == other.extraUsage
            && weekCost == other.weekCost
    }
}

/// `~/Library/Application Support/UsageTracker/last-known.json`, next to the
/// history log and written the same way: whole-file, atomic, and a file that
/// won't decode is ignored rather than fatal — last-known data is a convenience,
/// never a reason to fail a launch.
actor LastKnownStore {
    static let shared = LastKnownStore()

    private let fileURL: URL
    /// Loaded once; this actor is the only writer, so the cache can't go stale.
    private var entries: [String: LastKnownService]?

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
    static var defaultFileURL: URL {
        HistoryStore.defaultDirectory.appendingPathComponent("last-known.json")
    }

    /// Injectable location — the tests point it at a temp file.
    init(fileURL: URL = LastKnownStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() -> [String: LastKnownService] {
        if let entries { return entries }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([String: LastKnownService].self, from: data)
        else {
            entries = [:]
            return [:]
        }
        entries = decoded
        return decoded
    }

    /// Stores every service that actually reported something. A failing service is
    /// skipped, not cleared: its old entry is the whole point of this file.
    func remember(_ services: [ServiceSnapshot]) {
        var current = load()
        var changed = false
        for (index, service) in services.enumerated() {
            guard service.state == .ok, !service.buckets.isEmpty else { continue }
            let entry = LastKnownService(from: service, order: index)
            if let existing = current[service.id], existing.hasSameValues(as: entry) { continue }
            current[service.id] = entry
            changed = true
        }
        guard changed else { return }
        entries = current
        write(current)
    }

    private func write(_ entries: [String: LastKnownService]) {
        do {
            try encoder.encode(entries).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[UT] LastKnownStore write failed: %@", String(describing: error))
        }
    }
}
