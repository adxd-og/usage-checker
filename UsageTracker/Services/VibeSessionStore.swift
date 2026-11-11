import Foundation

/// One vibe session as its unified store keeps it (spec 2026-11-10 Mistral provider § Local usage
/// (P2), Facts): `CURRENT`, `meta.json`, `generations/<seq>/projection-state.json` and
/// `journal/<seq>.jsonl` under `~/.vibe/logs/session/unified/<session-id>/`. Pure readers over
/// files and bytes; what the points mean is `VibeLedger`'s rule.
enum VibeSessionStore {
    /// The one store format read (spec § Unknown store). `store_format_minor` is not looked at:
    /// a minor version keeps the format's name.
    static let storeFormat = "mistral.vibe.unified-session-store/v1"

    /// vibe's cumulative count for the session at one moment, from a generation's snapshot or a
    /// journal step's `set_envelope`. `input` includes `cached` (45 909 with 44 544 cached on
    /// this Mac); `output` includes reasoning. Never negative (`point(session:)` clamps).
    struct Point: Equatable, Sendable {
        let at: Date
        let input: Int
        let cached: Int
        let output: Int

        /// vibe's `totalTokens`: input + output, saturating, so a counter near `Int.max` in a
        /// damaged line reads as `Int.max` and never traps (spec § What the app has already
        /// counted).
        var total: Int { TokenBreakdown.saturating(input, output) }
    }

    /// What `meta.json` says about the session.
    struct Meta: Codable, Equatable, Sendable {
        var title: String?
        /// `environment.working_directory`: where the session ran.
        var workingDirectory: String?
        /// `config.active_model`: the model as vibe names it (`glm-5-3`), the session's model in
        /// every row.
        var activeModel: String?
        /// `config.model_name`: the id vibe sends (`zai-glm-5-3`), tried after the alias when
        /// the session is priced.
        var modelName: String?
    }

    /// A session directory's files as they were when it was read: while nothing moves, it is not
    /// read again.
    struct Mark: Codable, Equatable, Sendable {
        var newest: Date
        var bytes: Int64
        var files: Int
    }

    /// What one session directory holds.
    enum Contents: Equatable, Sendable {
        /// `CURRENT` names another store format, or none: skipped whole, never guessed at.
        case unknownStore(String?)
        /// Its meta and every point on disk, oldest first.
        case session(Meta, [Point])
    }

    /// The bytes a journal line must carry to hold a step's total. A segment is mostly model
    /// input and output: on this Mac a 13-minute session's segment is 13.3 MB and its 248
    /// envelope lines 2.5 MB (10 KB on average, 68 KB at most, since each carries the step's
    /// `append_entry`), so only those lines are parsed.
    static let setEnvelopeMarker = Data(#""set_envelope""#.utf8)

    // MARK: - A directory

    /// Every point on disk: each generation's snapshot and each journal segment's steps, sorted
    /// by moment, a tie keeping the smaller total first.
    static func read(_ directory: URL) -> Contents {
        guard let current = try? Data(contentsOf: directory.appendingPathComponent("CURRENT")) else {
            return .unknownStore(nil)
        }
        let found = Self.format(current: current)
        guard found == storeFormat else { return .unknownStore(found) }
        let meta = (try? Data(contentsOf: directory.appendingPathComponent("meta.json"))).map { Self.meta($0) } ?? Meta()
        var all: [Point] = []
        for generation in children(of: directory.appendingPathComponent("generations")) {
            if let data = try? Data(contentsOf: generation.appendingPathComponent("projection-state.json")),
               let snapshot = Self.point(projectionState: data) {
                all.append(snapshot)
            }
        }
        for segment in children(of: directory.appendingPathComponent("journal")) where segment.pathExtension == "jsonl" {
            if let data = try? Data(contentsOf: segment, options: .mappedIfSafe) {
                all += Self.points(journal: data)
            }
        }
        all.sort { ($0.at, $0.total) < ($1.at, $1.total) }
        return .session(meta, all)
    }

    /// The directory's mark: its `CURRENT`, `meta.json`, every generation's `projection-state.json`
    /// and every journal segment, by newest modification, bytes and count. nil without
    /// `CURRENT`: not a session.
    static func mark(of directory: URL) -> Mark? {
        let fm = FileManager.default
        let current = directory.appendingPathComponent("CURRENT")
        guard fm.fileExists(atPath: current.path) else { return nil }
        var files = [current, directory.appendingPathComponent("meta.json")]
        files += children(of: directory.appendingPathComponent("generations"))
            .map { $0.appendingPathComponent("projection-state.json") }
        files += children(of: directory.appendingPathComponent("journal"))
        var mark = Mark(newest: .distantPast, bytes: 0, files: 0)
        for file in files {
            // `FileManager`, not `URL.resourceValues`: a URL keeps the values it was first asked.
            guard let attributes = try? fm.attributesOfItem(atPath: file.path) else { continue }
            mark.files += 1
            mark.bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let modified = attributes[.modificationDate] as? Date, modified > mark.newest {
                mark.newest = modified
            }
        }
        return mark
    }

    /// A directory's entries, oldest sequence first (vibe zero-pads the names); none when the
    /// directory is missing.
    static func children(of directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Bytes

    /// `CURRENT`'s `store_format`; nil when the file is not the JSON object vibe writes.
    static func format(current data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["store_format"] as? String
    }

    /// A generation's `snapshot.session`; nil while the session has made no model call
    /// (`tokenUsage` null).
    static func point(projectionState data: Data) -> Point? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = object["snapshot"] as? [String: Any],
              let session = snapshot["session"] as? [String: Any]
        else { return nil }
        return point(session: session)
    }

    /// The totals in one journal line: a `projection_delta` record's `payload.delta[]` items with
    /// `op: "set_envelope"`. Any other record, `action_result` and `core_input` with their
    /// per-call `usage` included, gives none.
    static func points(journalLine data: Data) -> [Point] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "projection_delta",
              let payload = object["payload"] as? [String: Any],
              let delta = payload["delta"] as? [[String: Any]]
        else { return [] }
        return delta.compactMap { item in
            guard item["op"] as? String == "set_envelope",
                  let state = item["state"] as? [String: Any],
                  let session = state["session"] as? [String: Any]
            else { return nil }
            return point(session: session)
        }
    }

    /// Every total of a journal segment, in the order written. A half-written last line does
    /// not parse and is read whole at the next read.
    static func points(journal data: Data) -> [Point] {
        var found: [Point] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true)
        where line.range(of: setEnvelopeMarker) != nil {
            found += points(journalLine: Data(line))
        }
        return found
    }

    /// A `session` object's `tokenUsage` at its `updatedAt` (epoch milliseconds), never its
    /// `contextUsage`, which is the newest call's context in the same four keys. Each counter is
    /// clamped at zero.
    static func point(session: [String: Any]) -> Point? {
        guard let usage = session["tokenUsage"] as? [String: Any],
              let input = int(usage["inputTokens"]),
              let output = int(usage["outputTokens"]),
              let milliseconds = (session["updatedAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return Point(
            at: Date(timeIntervalSince1970: milliseconds / 1000),
            input: max(0, input),
            cached: max(0, int(usage["cachedInputTokens"]) ?? 0),
            output: max(0, output)
        )
    }

    /// `meta.json`'s title, working directory and two model ids; all nil when it is not the JSON
    /// object vibe writes.
    static func meta(_ data: Data) -> Meta {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Meta() }
        let environment = object["environment"] as? [String: Any]
        let config = object["config"] as? [String: Any]
        return Meta(
            title: object["title"] as? String,
            workingDirectory: environment?["working_directory"] as? String,
            activeModel: config?["active_model"] as? String,
            modelName: config?["model_name"] as? String
        )
    }

    private static func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let number = any as? NSNumber { return number.intValue }
        return nil
    }
}
