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
///
/// Every access is serialised by an advisory lock on a sidecar file, because the two
/// writers really do run at once: `rotate()` is detached at launch while sessions keep
/// ending on the main actor. See `withLock`.
final class AgentHistoryStore {
    private let fileURL: URL

    /// The lock lives beside the log, never on it: rotation replaces the log by
    /// renaming a temp file over it, so a lock held on the log's own inode would be
    /// a lock on a file nobody writes to any more.
    private var lockURL: URL { URL(fileURLWithPath: fileURL.path + ".lock") }

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

        // The whole append is inside the lock, and the write handle is opened after
        // it: a handle opened before a rotation's rename writes into the unlinked
        // inode, so those bytes would be gone the moment the rename lands.
        try withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
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
    }

    func load() throws -> [AgentSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        // Shared: any number of readers, but never while a rotation is rewriting.
        return try withLock(LOCK_SH) { parse(try Data(contentsOf: fileURL)).records }
    }

    /// Trims the log to the last `keepDays` of finished sessions, the same 90-day
    /// window `HistoryStore` keeps for usage points. Records are kept on `endedAt`:
    /// a run that started before the window but finished inside it is recent work.
    ///
    /// The rewrite is atomic and happens only when there is something to change — a
    /// dropped record or a corrupt line — so the common launch touches no bytes at all.
    /// A missing file is a no-op: rotation must never be what creates the log.
    func rotate(keepDays: Int = 90, now: Date = Date()) throws {
        // Checked before the lock too, so rotating a log that was never written
        // doesn't leave a lock file behind in an otherwise untouched directory.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // Read, filter and rename are one critical section: an append landing in
        // the middle of them would be read after it was written and dropped before
        // it was kept.
        try withLock {
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
    }

    // MARK: - Locking

    /// Runs `body` holding an advisory `flock` on the sidecar lock file — `LOCK_EX`
    /// for the writers, `LOCK_SH` for `load`. The lock is per open-file-description,
    /// so two `AgentHistoryStore`s pointed at the same log (the main actor's and the
    /// detached rotation's) exclude each other correctly.
    private func withLock<T>(_ operation: Int32 = LOCK_EX, _ body: () throws -> T) throws -> T {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Self.posixError(errno, path: lockURL.path) }
        defer { close(fd) }
        while flock(fd, operation) != 0 {
            // A signal is the only retryable failure; anything else means the lock
            // can't be taken, and writing without it risks losing records.
            guard errno == EINTR else { throw Self.posixError(errno, path: lockURL.path) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func posixError(_ code: Int32, path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
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
