import Foundation

/// One finished agent session, summarised. Deliberately narrow: the spec forbids
/// persisting anything from a hook payload, so there is no cwd, no tool name and no
/// tool input here — only what the phase-3 "run history" needs to draw a row.
struct AgentSessionRecord: Codable, Equatable {
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
        let data = try Data(contentsOf: fileURL)
        var records: [AgentSessionRecord] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let record = try? decoder.decode(AgentSessionRecord.self, from: Data(line)) else { continue }
            records.append(record)
        }
        return records
    }
}
