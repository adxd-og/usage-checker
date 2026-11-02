import Foundation

/// Claude's limits as Claude Code's status line left them (spec 2026-11-02 Claude limits
/// from the status line, § Design › App): the folder `brioche statusline` writes
/// (`StatusLineDrop`), one file per session, read into `StatusLineFreshnessRules`' table.
///
/// An actor, so two loads never read the folder at once. The folder is injected — tests
/// point it at a temp directory — and defaults to the one the CLI writes, by the CLI's own
/// rule (`StatusLineDrop.directoryURL`). Loading also sweeps: a reading, or a temp file a
/// killed writer left, older than an hour goes.
actor StatusLineReadingStore {
    static let shared = StatusLineReadingStore()

    /// A reading or a writer's temp file older than this is deleted. Ten minutes already
    /// ended its session (`StatusLineFreshnessRules.evictionAge`).
    static let sweepAge: TimeInterval = 3600

    private let directoryURL: URL
    private var table: [String: StatusLineFreshnessRules.Session] = [:]

    init(directoryURL: URL = StatusLineDrop.directoryURL()) {
        self.directoryURL = directoryURL
    }

    /// The sessions as the last load left them, in id order.
    var sessions: [StatusLineFreshnessRules.Session] {
        table.values.sorted { $0.sessionID < $1.sessionID }
    }

    /// Reads the folder at `now`: sweeps what is old, reads every reading, advances each
    /// session. A missing or unreadable folder is an empty one, and is not made here.
    @discardableResult
    func load(now: Date) -> [StatusLineFreshnessRules.Session] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        var readings: [StatusLineDrop.Reading] = []
        for name in names.sorted() {
            let url = directoryURL.appendingPathComponent(name, isDirectory: false)
            if Self.isSwept(name: name),
               let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Self.isOld(modifiedAt: modified, now: now) {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard Self.isReading(name: name),
                  let data = try? Data(contentsOf: url),
                  let reading = Self.reading(from: data, named: name)
            else { continue }
            readings.append(reading)
        }
        table = StatusLineFreshnessRules.table(table, readings: readings, now: now)
        return sessions
    }

    /// A reading's name: `<session_id>.json`, never a hidden file — the writer's temp file
    /// is `.<session_id>.json.<UUID>.tmp` — so a half-written file is never opened.
    nonisolated static func isReading(name: String) -> Bool {
        !name.hasPrefix(".") && name.hasSuffix(".json")
    }

    /// What the sweep may delete once it is old: a reading, or a temp file a writer killed
    /// between its write and its rename left behind. Nothing else in the folder is ours.
    nonisolated static func isSwept(name: String) -> Bool {
        isReading(name: name) || (name.hasPrefix(".") && name.hasSuffix(".tmp"))
    }

    nonisolated static func isOld(modifiedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(modifiedAt) > sweepAge
    }

    /// The reading a file holds, when it is in a format this build reads and sits under its
    /// own session's name. A file renamed by hand, or one carrying another session's id, is
    /// not read: one session, one file.
    nonisolated static func reading(from data: Data, named name: String) -> StatusLineDrop.Reading? {
        guard let reading = try? StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: data),
              reading.formatVersion == StatusLineDrop.Reading.currentFormatVersion,
              StatusLineDrop.fileName(sessionID: reading.sessionID) == name
        else { return nil }
        return reading
    }
}
