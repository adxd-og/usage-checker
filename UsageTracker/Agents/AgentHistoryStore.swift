import Foundation

/// One finished agent session, summarised. Deliberately narrow: the spec forbids
/// persisting anything from a hook payload, so there is no cwd, no tool name and no
/// tool input here — only what the phase-3 "run history" needs to draw a row.
struct AgentSessionRecord: Codable, Equatable, Sendable {
    let id: String
    let source: AgentSource
    let project: String
    let startedAt: Date
    let endedAt: Date
    /// Prompts the user submitted during the session.
    let turns: Int
    /// How many times the session waited for an approval.
    let needsYouCount: Int
}

/// Append-only JSONL log of finished agent sessions, the same shape `HistoryStore`
/// uses for usage points: one record per line, appended with a seek-to-end write so a
/// session ending never rewrites the whole file, and a line that fails to decode is
/// skipped instead of discarding everything after it.
final class AgentHistoryStore {
    private let fileURL: URL

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

    /// Injectable log location — the tests point it at a temp directory instead of
    /// `~/Library/Application Support/UsageTracker/agent-sessions.jsonl`.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ record: AgentSessionRecord) throws {
        var data = try encoder.encode(record)
        data.append(0x0A)

        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: fileURL.path) else {
            // No file yet: one atomic write creates it with this first record.
            try data.write(to: fileURL, options: [.atomic])
            return
        }
        // Any other open failure (EMFILE, permissions, an immutable flag) must
        // propagate — falling back to the atomic write above would replace the
        // whole log with a single record.
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func load() throws -> [AgentSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return parse(try Data(contentsOf: fileURL)).records
    }

    /// Trims the log to the last `keepDays` of finished sessions, the same 90-day
    /// window `HistoryStore` keeps for usage points. Records are kept on `endedAt`:
    /// a run that started before the window but finished inside it is recent work.
    ///
    /// The rewrite is atomic and happens only when there is something to change — a
    /// dropped record or a corrupt line — so the common launch touches no bytes at all.
    /// A missing file is a no-op: rotation must never be what creates the log.
    func rotate(keepDays: Int = 90, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let parsed = parse(try Data(contentsOf: fileURL))
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 24 * 3600)
        let kept = parsed.records.filter { $0.endedAt >= cutoff }
        guard kept.count != parsed.records.count || parsed.corrupt > 0 else { return }

        var data = Data()
        for record in kept {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    /// One line per record; a line that fails to decode is counted and skipped rather
    /// than discarding everything after it.
    private func parse(_ data: Data) -> (records: [AgentSessionRecord], corrupt: Int) {
        var records: [AgentSessionRecord] = []
        var corrupt = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(AgentSessionRecord.self, from: Data(line)) {
                records.append(record)
            } else {
                corrupt += 1
            }
        }
        return (records, corrupt)
    }
}
