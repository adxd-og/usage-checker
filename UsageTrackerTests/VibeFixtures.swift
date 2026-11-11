import Foundation

/// vibe 3.1.0's unified session store as it stood on this Mac on 2026-11-06 (spec 2026-11-10
/// Mistral provider § Local usage (P2), Facts): the record shapes of
/// `~/.vibe/logs/session/unified/<session-id>/`, numbers and times kept, session ids, titles,
/// message text, hashes, usernames and paths replaced. `write(_:under:)` lays a session out
/// under a test's own temp root; no test reads the real `~/.vibe`.
enum VibeFixture {
    static let storeFormat = "mistral.vibe.unified-session-store/v1"
    private static let zeroHash = String(repeating: "0", count: 64)

    /// A `tokenUsage` object: `input` includes `cached`; `total` is input + output, saturating
    /// so a test can write a counter near `Int.max`.
    struct Usage: Equatable {
        let input: Int
        let cached: Int
        let output: Int

        var total: Int {
            let (sum, overflow) = input.addingReportingOverflow(output)
            return overflow ? Int.max : sum
        }
    }

    /// One session directory.
    struct Session {
        var id: String
        var title: String? = "Fixture title"
        var workingDirectory: String? = "/tmp/Vibe Fixtures/probe"
        var activeModel: String? = "mistral-large-4-0-3"
        var modelName: String? = "mistral-large-4-0"
        var createdMs: Int64
        var format: String = VibeFixture.storeFormat
        /// The generation `CURRENT` names.
        var currentGeneration: Int
        /// Generation number → its snapshot's `tokenUsage` (nil before any model call) and
        /// `updatedAt`.
        var generations: [Int: (usage: Usage?, ms: Int64)]
        /// A journal segment's first sequence → its lines, in order. An empty list is the
        /// empty newest segment an idle session keeps.
        var journals: [Int: [String]]
    }

    /// Writes `session` under `root` as vibe lays it out and returns its directory.
    @discardableResult
    static func write(_ session: Session, under root: URL) throws -> URL {
        let fm = FileManager.default
        let directory = root.appendingPathComponent(session.id, isDirectory: true)
        try fm.createDirectory(at: directory.appendingPathComponent("journal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("generations"), withIntermediateDirectories: true)
        try Data(current(session).utf8).write(to: directory.appendingPathComponent("CURRENT"))
        try Data(meta(session).utf8).write(to: directory.appendingPathComponent("meta.json"))
        for (number, snapshot) in session.generations {
            let folder = directory.appendingPathComponent("generations/\(sequenceName(number))", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(projectionState(session, generation: number, usage: snapshot.usage, ms: snapshot.ms).utf8)
                .write(to: folder.appendingPathComponent("projection-state.json"))
        }
        for (first, lines) in session.journals {
            let text = lines.map { $0 + "\n" }.joined()
            try Data(text.utf8).write(to: directory.appendingPathComponent("journal/\(sequenceName(first)).jsonl"))
        }
        return directory
    }

    /// vibe's zero-padded sequence names: `0000000000000332`.
    static func sequenceName(_ number: Int) -> String {
        String(format: "%016ld", number)
    }

    static func current(_ s: Session) -> String {
        #"{"generation":"\#(sequenceName(s.currentGeneration))","manifest_sha256":"\#(zeroHash)","session_id":"\#(s.id)","snapshot_sequence":\#(s.currentGeneration),"store_format":"\#(s.format)","store_format_minor":10}"# + "\n"
    }

    static func meta(_ s: Session) throws -> String {
        func value(_ text: String?) -> Any { text.map { $0 as Any } ?? NSNull() }
        let object: [String: Any] = [
            "session_id": s.id,
            "parent_session_id": NSNull(),
            "start_time": "2026-11-06T14:00:00.000000+00:00",
            "end_time": "2026-11-06T16:00:00.000000+00:00",
            "git_commit": NSNull(),
            "git_branch": NSNull(),
            "environment": ["working_directory": value(s.workingDirectory)],
            "origin_directory": value(s.workingDirectory),
            "username": "fixture",
            "child_sessions": [String](),
            "loops": [String](),
            "title": value(s.title),
            "title_source": "auto",
            "pinned_at": NSNull(),
            "archived_at": NSNull(),
            "experiments": NSNull(),
            "config": ["active_model": value(s.activeModel), "model_name": value(s.modelName)],
            "runtime_path": "session_api",
            "import_provenance": NSNull(),
            "created_worktree": NSNull(),
            "project": NSNull(),
            "artifacts": [String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func usageJSON(_ usage: Usage?) -> String {
        guard let usage else { return "null" }
        return #"{"cachedInputTokens":\#(usage.cached),"inputTokens":\#(usage.input),"outputTokens":\#(usage.output),"totalTokens":\#(usage.total)}"#
    }

    /// A generation's `projection-state.json`. Generation 1 is vibe's snapshot before the first
    /// record (`snapshot_sequence` 0); every later one is numbered by its sequence.
    static func projectionState(_ s: Session, generation: Int, usage: Usage?, ms: Int64) -> String {
        let sequence = generation == 1 ? 0 : generation
        return #"{"projection_state_version":1,"session_id":"\#(s.id)","snapshot":{"activeCallbacks":[],"format":"harness.public-session-state/v1","history":{"cursor":{"after":null,"before":null},"entries":[],"range":"latest"},"latestTurn":null,"session":{"contextUsage":null,"createdAt":\#(s.createdMs),"id":"\#(s.id)","parentSessionId":null,"preview":"","rootSessionId":"\#(s.id)","status":{"type":"idle"},"title":null,"titleSource":"auto","tokenUsage":\#(usageJSON(usage)),"updatedAt":\#(ms)},"turnQueue":{"items":[],"maxItems":32,"paused":false}},"snapshot_sequence":\#(sequence),"watermark":0}"#
    }

    /// The `projection_delta` vibe writes after every step: an `append_entry`, then the
    /// `set_envelope` whose session carries the cumulative `tokenUsage` beside `contextUsage`,
    /// the newest call's context in the same four keys.
    static func envelope(_ s: Session, sequence: Int, usage: Usage?, ms: Int64, context: Usage? = nil) -> String {
        #"{"payload":{"delta":[{"entry":{"createdAt":\#(ms),"generationStatus":"completed","id":"entry-\#(sequence)","inputEntryId":null,"relatedEntryId":null,"sessionId":"\#(s.id)","summary":[],"text":"Fixture reasoning","turnId":"turn-1","type":"reasoning","updatedAt":\#(ms)},"op":"append_entry"},{"op":"set_envelope","state":{"activeCallbacks":[],"format":"harness.public-session-state/v1","history":{"cursor":{"after":null,"before":null},"entries":[],"range":"latest"},"latestTurn":null,"session":{"contextUsage":\#(usageJSON(context)),"createdAt":\#(s.createdMs),"id":"\#(s.id)","parentSessionId":null,"preview":"","rootSessionId":"\#(s.id)","status":{"type":"idle"},"title":null,"titleSource":"auto","tokenUsage":\#(usageJSON(usage)),"updatedAt":\#(ms)},"turnQueue":{"items":[],"maxItems":32,"paused":false}}}],"watermark":\#(sequence)},"previous_record_sha256":"\#(zeroHash)","record_sha256":"\#(zeroHash)","recovery_journal_record_version":1,"sequence":\#(sequence),"type":"projection_delta"}"#
    }

    /// A model call's result with its own per-call `usage` (snake_case): never a point.
    static func actionResult(sequence: Int, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        #"{"payload":{"action_id":"action-\#(sequence)","result":{"action_id":"action-\#(sequence)","result":{"finish_reason":"stop","parts":[{"_meta":{"closed":true},"content":[{"text":"Fixture output","type":"text"}],"type":"reasoning"}],"usage":{"cache_write_tokens":0,"cached_input_tokens":\#(cached),"input_tokens":\#(input),"output_tokens":\#(output),"reasoning_tokens":\#(reasoning),"total_tokens":\#(input + output)}},"type":"completion_succeeded"},"state":"succeeded"},"previous_record_sha256":"\#(zeroHash)","record_sha256":"\#(zeroHash)","recovery_journal_record_version":1,"sequence":\#(sequence),"type":"action_result"}"#
    }

    /// A user message whose whole text is `set_envelope`: it carries the marker's bytes and is
    /// still not a point.
    static func messageNamingTheMarker(_ s: Session, sequence: Int, ms: Int64) -> String {
        #"{"payload":{"delta":[{"entry":{"content":[{"text":"set_envelope","type":"text"}],"createdAt":\#(ms),"generationStatus":"completed","id":"entry-\#(sequence)","inputEntryId":null,"relatedEntryId":null,"role":"user","sessionId":"\#(s.id)","source":"turn_start","turnId":"turn-1","type":"message","updatedAt":\#(ms)},"op":"append_entry"}],"watermark":\#(sequence)},"previous_record_sha256":"\#(zeroHash)","record_sha256":"\#(zeroHash)","recovery_journal_record_version":1,"sequence":\#(sequence),"type":"projection_delta"}"#
    }

    // MARK: - The sessions

    /// A real session, mistral-large-4-0-3: its first generation and its whole journal. A step
    /// before any model call, then six totals from 9 712 to 66 132 (vibe writes each four times;
    /// the first twice here), a call's own usage and a message naming the marker.
    static func whole(id: String = "00000000-0000-4000-8000-000000000393") -> Session {
        var s = Session(id: id, createdMs: 1_793_977_653_690, currentGeneration: 73, generations: [:], journals: [:])
        s.generations = [
            1: (nil, 1_793_977_653_690),
            73: (Usage(input: 63_031, cached: 45_568, output: 3_101), 1_793_977_736_011),
        ]
        s.journals = [
            1: [
                envelope(s, sequence: 3, usage: nil, ms: 1_793_977_654_444),
                messageNamingTheMarker(s, sequence: 4, ms: 1_793_977_654_444),
                actionResult(sequence: 5, input: 7_180, cached: 2_816, output: 2_532, reasoning: 0),
                envelope(s, sequence: 7, usage: Usage(input: 7_180, cached: 2_816, output: 2_532), ms: 1_793_977_712_751),
                envelope(s, sequence: 9, usage: Usage(input: 7_180, cached: 2_816, output: 2_532), ms: 1_793_977_712_759),
                envelope(s, sequence: 20, usage: Usage(input: 18_093, cached: 9_728, output: 2_579), ms: 1_793_977_714_212,
                         context: Usage(input: 10_913, cached: 6_912, output: 47)),
                envelope(s, sequence: 33, usage: Usage(input: 29_115, cached: 12_800, output: 2_697), ms: 1_793_977_720_616),
                envelope(s, sequence: 46, usage: Usage(input: 40_314, cached: 23_552, output: 2_747), ms: 1_793_977_728_714),
                envelope(s, sequence: 59, usage: Usage(input: 51_611, cached: 34_560, output: 2_822), ms: 1_793_977_733_201),
                envelope(s, sequence: 72, usage: Usage(input: 63_031, cached: 45_568, output: 3_101), ms: 1_793_977_736_011,
                         context: Usage(input: 11_420, cached: 11_008, output: 279)),
            ],
            74: [],
        ]
        return s
    }

    /// A real session, mistral-large-4-0-3: vibe pruned the early segments. Generations 323 and
    /// 332, journal 324 (three steps, the first two repeating generation 323's 751 847, then
    /// 797 997) and the empty journal 333.
    static func pruned(id: String = "00000000-0000-4000-8000-000000000a40") -> Session {
        var s = Session(
            id: id, workingDirectory: "/tmp/Vibe Fixtures/movie app", createdMs: 1_793_974_760_815,
            currentGeneration: 332, generations: [:], journals: [:]
        )
        s.generations = [
            323: (Usage(input: 745_677, cached: 623_104, output: 6_170), 1_793_978_821_829),
            332: (Usage(input: 791_586, cached: 667_648, output: 6_411), 1_793_978_907_387),
        ]
        s.journals = [
            324: [
                envelope(s, sequence: 324, usage: Usage(input: 745_677, cached: 623_104, output: 6_170), ms: 1_793_978_822_878,
                         context: Usage(input: 44_992, cached: 39_936, output: 906)),
                envelope(s, sequence: 327, usage: Usage(input: 745_677, cached: 623_104, output: 6_170), ms: 1_793_978_894_224),
                actionResult(sequence: 329, input: 45_909, cached: 44_544, output: 241, reasoning: 123),
                envelope(s, sequence: 331, usage: Usage(input: 791_586, cached: 667_648, output: 6_411), ms: 1_793_978_907_387,
                         context: Usage(input: 45_909, cached: 44_544, output: 241)),
            ],
            333: [],
        ]
        return s
    }

    /// A real session, mistral-large-4-0-3: one total, 6 997, written three times.
    static func repeated(id: String = "00000000-0000-4000-8000-0000000003b0") -> Session {
        var s = Session(id: id, createdMs: 1_793_977_619_824, currentGeneration: 13, generations: [:], journals: [:])
        s.generations = [
            1: (nil, 1_793_977_619_824),
            13: (Usage(input: 6_930, cached: 3_072, output: 67), 1_793_977_638_323),
        ]
        s.journals = [
            1: [
                envelope(s, sequence: 3, usage: nil, ms: 1_793_977_620_913),
                envelope(s, sequence: 7, usage: Usage(input: 6_930, cached: 3_072, output: 67), ms: 1_793_977_627_409),
                envelope(s, sequence: 9, usage: Usage(input: 6_930, cached: 3_072, output: 67), ms: 1_793_977_627_414),
                envelope(s, sequence: 12, usage: Usage(input: 6_930, cached: 3_072, output: 67), ms: 1_793_977_638_323),
            ],
            14: [],
        ]
        return s
    }

    /// A real session, mistral-medium-3.5: opened and closed, no model call, no `tokenUsage` anywhere.
    static func noTotal(id: String = "00000000-0000-4000-8000-0000000000d8") -> Session {
        var s = Session(
            id: id, activeModel: "mistral-medium-3.5", modelName: "mistral-vibe-cli-latest",
            createdMs: 1_793_974_581_965, currentGeneration: 8, generations: [:], journals: [:]
        )
        s.generations = [1: (nil, 1_793_974_581_965), 8: (nil, 1_793_974_582_775)]
        s.journals = [
            1: [
                envelope(s, sequence: 3, usage: nil, ms: 1_793_974_582_547),
                envelope(s, sequence: 7, usage: nil, ms: 1_793_974_582_775),
            ],
            9: [],
        ]
        return s
    }

    /// A real session: vibe's alias `glm-5-3`, sent to Mistral as `zai-glm-5-3`. One step, 6 866.
    static func glm(id: String = "00000000-0000-4000-8000-0000000000a9") -> Session {
        var s = Session(
            id: id, activeModel: "glm-5-3", modelName: "zai-glm-5-3",
            createdMs: 1_793_975_676_641, currentGeneration: 8, generations: [:], journals: [:]
        )
        s.generations = [
            1: (nil, 1_793_975_676_641),
            8: (Usage(input: 6_863, cached: 5_952, output: 3), 1_793_975_678_956),
        ]
        s.journals = [
            1: [envelope(s, sequence: 7, usage: Usage(input: 6_863, cached: 5_952, output: 3), ms: 1_793_975_678_956)],
            9: [],
        ]
        return s
    }

    /// A real session: vibe's default model, alias `mistral-medium-3.5` sent as
    /// `mistral-vibe-cli-latest` (vibe 3.1.0's `DEFAULT_ACTIVE_MODEL_CONFIG`). One step, 7 065.
    static func medium(id: String = "00000000-0000-4000-8000-0000000000c3") -> Session {
        var s = Session(
            id: id, activeModel: "mistral-medium-3.5", modelName: "mistral-vibe-cli-latest",
            createdMs: 1_793_975_680_645, currentGeneration: 8, generations: [:], journals: [:]
        )
        s.generations = [
            1: (nil, 1_793_975_680_645),
            8: (Usage(input: 7_027, cached: 3_200, output: 38), 1_793_975_682_731),
        ]
        s.journals = [
            1: [envelope(s, sequence: 7, usage: Usage(input: 7_027, cached: 3_200, output: 38), ms: 1_793_975_682_731)],
            9: [],
        ]
        return s
    }

    /// A real session, glm-5-3 sent as zai-glm-5-3: four of its 51 totals, two before and two
    /// after 15:15 UTC, which is midnight in Australia/Eucla (UTC+08:45, no daylight saving):
    /// 1 623 625 tokens on 6 November there, 6 822 727 on the 7th.
    static func midnight(id: String = "00000000-0000-4000-8000-0000000006a6") -> Session {
        var s = Session(
            id: id, activeModel: "glm-5-3", modelName: "zai-glm-5-3",
            createdMs: 1_793_977_611_352, currentGeneration: 806, generations: [:], journals: [:]
        )
        s.generations = [
            1: (nil, 1_793_977_611_352),
            806: (Usage(input: 8_401_641, cached: 8_000_960, output: 44_711), 1_793_978_609_343),
        ]
        s.journals = [
            1: [
                envelope(s, sequence: 7, usage: Usage(input: 7_207, cached: 640, output: 88), ms: 1_793_977_614_876),
                envelope(s, sequence: 335, usage: Usage(input: 1_620_647, cached: 1_449_024, output: 2_978), ms: 1_793_977_673_014),
                envelope(s, sequence: 384, usage: Usage(input: 1_802_736, cached: 1_622_336, output: 18_679), ms: 1_793_978_272_490),
                envelope(s, sequence: 805, usage: Usage(input: 8_401_641, cached: 8_000_960, output: 44_711), ms: 1_793_978_609_343),
            ],
            807: [],
        ]
        return s
    }

    /// The same session once vibe has pruned it: generation 806 alone and the empty journal after it.
    static func midnightPruned(id: String = "00000000-0000-4000-8000-0000000006a6") -> Session {
        var s = midnight(id: id)
        s.generations = [806: (Usage(input: 8_401_641, cached: 8_000_960, output: 44_711), 1_793_978_609_343)]
        s.journals = [807: []]
        return s
    }
}
