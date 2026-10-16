import Foundation

/// `~/Library/Application Support/UsageTracker/worktrees.json`: the repository each git
/// worktree a session ran in belongs to (spec 2026-10-16 limit analytics § The tab, item 3).
/// A worktree is looked up while it is on disk (`ProjectWorktrees.lookup`) and remembered
/// here, so its chats still count under its repository after `git worktree remove`.
/// Written whole and atomically; a file that does not decode is ignored, as
/// `last-known.json` is.
actor WorktreeStore {
    static let shared = WorktreeStore()

    /// A link no session has used for this long is forgotten: no view of the cost logs
    /// reaches further back than Activity's year.
    static let retention: TimeInterval = 366 * 24 * 3600
    /// How often one directory is looked up again: a path whose worktree was removed can
    /// come back as another directory.
    static let lookupInterval: TimeInterval = 24 * 3600

    private let fileURL: URL
    /// By path. Loaded once; this actor is the only writer.
    private var stored: [String: WorktreeLink]?
    /// When each directory was last looked up, for `lookupInterval` only: an older entry
    /// would be looked up again anyway, so it is dropped, and this holds no more than one
    /// day's directories.
    private(set) var lookedUpAt: [String: Date] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Where the links are kept, worked out without touching the disk: `shared` is first
    /// reached from the main actor, and `HistoryStore.defaultDirectory` creates its folder.
    /// `save` makes the folder when there is something to write. Not private: it is the
    /// default argument of an internal initializer.
    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageTracker", isDirectory: true)
            .appendingPathComponent("worktrees.json")
    }

    /// Injectable location — the tests point it at a temp file. Touches no disk.
    init(fileURL: URL = WorktreeStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Looks up each directory a session runs in, at most once per `lookupInterval`, and
    /// keeps what it finds: a worktree's link, with `now` as its last use; no link for a
    /// directory that is on disk and in no worktree; the link as it was for one that is
    /// gone. Links unused for `retention` are dropped. The file is written only when
    /// something changed.
    func learn(paths: [String], now: Date = Date()) {
        lookedUpAt = lookedUpAt.filter { now.timeIntervalSince($0.value) < Self.lookupInterval }
        var current = load()
        var changed = false
        for path in Set(paths) {
            if let last = lookedUpAt[path], now.timeIntervalSince(last) < Self.lookupInterval { continue }
            lookedUpAt[path] = now
            switch ProjectWorktrees.lookup(path) {
            case .linked(let main):
                current[path] = WorktreeLink(path: path, main: main, seenAt: now)
                changed = true
            case .unlinked:
                if current.removeValue(forKey: path) != nil { changed = true }
            case .missing:
                break
            }
        }
        let kept = current.filter { now.timeIntervalSince($0.value.seenAt) < Self.retention }
        if kept.count != current.count { changed = true }
        stored = kept
        if changed { save(kept) }
    }

    /// Every link a session used within `retention` of `now`, the least recently used
    /// first.
    func links(now: Date = Date()) -> [WorktreeLink] {
        load().values
            .filter { now.timeIntervalSince($0.seenAt) < Self.retention }
            .sorted { $0.seenAt == $1.seenAt ? $0.path < $1.path : $0.seenAt < $1.seenAt }
    }

    private func load() -> [String: WorktreeLink] {
        if let stored { return stored }
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? decoder.decode([WorktreeLink].self, from: $0) } ?? []
        let byPath = Dictionary(
            decoded.map { ($0.path, $0) },
            uniquingKeysWith: { first, second in first.seenAt >= second.seenAt ? first : second }
        )
        stored = byPath
        return byPath
    }

    private func save(_ links: [String: WorktreeLink]) {
        do {
            let data = try encoder.encode(links.values.sorted { $0.path < $1.path })
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[UT] worktrees.json write failed: %@", String(describing: error))
        }
    }
}
