import Foundation

/// Claude's limits as Claude Code's status line left them (spec 2026-11-02 Claude limits
/// from the status line, § Design › App): the folder `brioche statusline` writes
/// (`StatusLineDrop`), one file per session, read into `StatusLineFreshnessRules`' table.
///
/// Read at every poll and whenever the folder changes (`startWatching`): a reading is dated
/// by the file in which its API time grew, and between two polls Claude Code may write
/// that file and re-run the line over it. A folder event moves the table. An actor, so a
/// poll and a folder event never read the
/// folder at once. The folder is injected — tests point it at a temp directory — and
/// defaults to the one the CLI writes, by the CLI's own rule (`StatusLineDrop.directoryURL`).
/// Loading also sweeps: a reading, or a temp file a killed writer left, older than an hour
/// goes.
actor StatusLineReadingStore {
    static let shared = StatusLineReadingStore()

    /// A reading or a writer's temp file older than this is deleted. Ten minutes already
    /// ended its session (`StatusLineFreshnessRules.evictionAge`).
    static let sweepAge: TimeInterval = 3600

    private static let watchQueue = DispatchQueue(label: "com.usagetracker.app.statusline-watch", qos: .utility)

    private let directoryURL: URL
    /// The clock a folder event loads with; a poll passes its own `now`. Tests pin it.
    private let clock: @Sendable () -> Date
    private var table: [String: StatusLineFreshnessRules.Session] = [:]
    private var watcher: DispatchSourceFileSystemObject?
    /// Set by `startWatching`: a watch the folder's removal ended is armed again by the
    /// next load.
    private var wantsWatching = false
    /// Told after every load a folder event caused, on this actor's executor — never the
    /// main actor; a listener that needs it hops there itself.
    private var onChange: (@Sendable () -> Void)?

    init(
        directoryURL: URL = StatusLineDrop.directoryURL(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL
        self.clock = clock
    }

    /// The sessions as the last load left them, in id order.
    var sessions: [StatusLineFreshnessRules.Session] {
        table.values.sorted { $0.sessionID < $1.sessionID }
    }

    /// Reads the folder at `now`: sweeps what is old, reads every reading, advances each
    /// session. A missing or unreadable folder is an empty one, and is not made here — only
    /// a watch makes it.
    @discardableResult
    func load(now: Date) -> [StatusLineFreshnessRules.Session] {
        if wantsWatching, watcher == nil { arm() }
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

    // MARK: - Watching the folder

    /// Loads the folder whenever something in it changes, besides every poll, then tells
    /// `onChange`: the app puts a new reading on screen between polls with it (session
    /// ruling 2026-11-02). Makes the folder when it is not there yet — a watch needs
    /// something to watch — owner-only (0700) as the CLI makes it, its parents with the
    /// default mode.
    func startWatching(onChange: (@Sendable () -> Void)? = nil) {
        wantsWatching = true
        self.onChange = onChange
        arm()
    }

    func stopWatching() {
        wantsWatching = false
        onChange = nil
        watcher?.cancel()
        watcher = nil
    }

    private func arm() {
        guard watcher == nil else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            do {
                try fileManager.createDirectory(
                    at: directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            } catch {
                return
            }
        }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: Self.watchQueue
        )
        // @Sendable, so neither block inherits this actor's isolation: GCD runs them on its
        // own queue, and an isolated block run there is what Swift 6 traps on.
        source.setEventHandler { @Sendable [weak self] in
            Task { await self?.folderChanged() }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
        watcher = source
        source.resume()
    }

    private func folderChanged() {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            // The folder itself went: this watch sees nothing more. The next load arms a
            // new one.
            watcher?.cancel()
            watcher = nil
            return
        }
        load(now: clock())
        onChange?()
    }

    // MARK: - Rules

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
