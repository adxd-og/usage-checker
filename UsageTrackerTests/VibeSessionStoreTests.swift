import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Facts and Design (Source, What the app has
/// already counted, Unknown store): a session directory is read into vibe's own timed cumulative
/// totals, one per generation snapshot and one per journal `set_envelope`, oldest first. Only
/// `tokenUsage` is a total (`contextUsage` is the newest call's context), a call's own `usage` is
/// never one, a store format other than v1 is skipped whole, and a counter near `Int.max` or below
/// zero neither traps nor goes negative.
final class VibeSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func assertPoint(
        _ point: VibeSessionStore.Point?, ms: Int64, input: Int, cached: Int, output: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let point else { return XCTFail("no point", file: file, line: line) }
        XCTAssertEqual(Int64((point.at.timeIntervalSince1970 * 1000).rounded()), ms, file: file, line: line)
        XCTAssertEqual(point.input, input, file: file, line: line)
        XCTAssertEqual(point.cached, cached, file: file, line: line)
        XCTAssertEqual(point.output, output, file: file, line: line)
    }

    private func milliseconds(_ point: VibeSessionStore.Point?) -> Int64? {
        point.map { Int64(($0.at.timeIntervalSince1970 * 1000).rounded()) }
    }

    func testAGenerationGivesItsTotalAtItsUpdatedAt() {
        let state = VibeFixture.projectionState(
            VibeFixture.pruned(), generation: 323,
            usage: VibeFixture.Usage(input: 745_677, cached: 623_104, output: 6_170), ms: 1_793_978_821_829
        )
        assertPoint(
            VibeSessionStore.point(projectionState: Data(state.utf8)),
            ms: 1_793_978_821_829, input: 745_677, cached: 623_104, output: 6_170
        )
    }

    func testAGenerationBeforeAnyModelCallGivesNoPoint() {
        let state = VibeFixture.projectionState(VibeFixture.whole(), generation: 1, usage: nil, ms: 1_793_977_653_690)
        XCTAssertNil(VibeSessionStore.point(projectionState: Data(state.utf8)))
    }

    func testAStepsTotalIsItsTokenUsageNeverItsContextUsage() {
        let line = VibeFixture.envelope(
            VibeFixture.whole(), sequence: 20,
            usage: VibeFixture.Usage(input: 18_093, cached: 9_728, output: 2_579), ms: 1_793_977_714_212,
            context: VibeFixture.Usage(input: 10_913, cached: 6_912, output: 47)
        )
        let points = VibeSessionStore.points(journalLine: Data(line.utf8))
        XCTAssertEqual(points.count, 1)
        assertPoint(points.first, ms: 1_793_977_714_212, input: 18_093, cached: 9_728, output: 2_579)
        XCTAssertEqual(points.first?.total, 20_672, "input already includes the cached tokens")
    }

    func testOnlyASetEnvelopeInAProjectionDeltaIsAPoint() {
        let session = VibeFixture.whole()
        let call = VibeFixture.actionResult(sequence: 329, input: 45_909, cached: 44_544, output: 241, reasoning: 123)
        XCTAssertTrue(VibeSessionStore.points(journalLine: Data(call.utf8)).isEmpty, "a call's own usage is not the session's total")
        let message = VibeFixture.messageNamingTheMarker(session, sequence: 4, ms: 1_793_977_654_444)
        XCTAssertTrue(VibeSessionStore.points(journalLine: Data(message.utf8)).isEmpty, "a message that says set_envelope is a message")
        let early = VibeFixture.envelope(session, sequence: 3, usage: nil, ms: 1_793_977_654_444)
        XCTAssertTrue(VibeSessionStore.points(journalLine: Data(early.utf8)).isEmpty, "a step before any model call has no total")
    }

    func testAWholeSessionReadsEveryPointOldestFirst() throws {
        let directory = try VibeFixture.write(VibeFixture.whole(), under: root)
        guard case .session(let meta, let points) = VibeSessionStore.read(directory) else { return XCTFail("not read") }
        XCTAssertEqual(meta.activeModel, "mistral-large-4-0-3")
        XCTAssertEqual(
            points.map(\.total), [9_712, 9_712, 20_672, 31_812, 43_061, 54_433, 66_132, 66_132],
            "seven journal steps, then generation 73 at the same moment as the last; generation 1 has none"
        )
        XCTAssertEqual(milliseconds(points.first), 1_793_977_712_751)
    }

    func testAPrunedSessionStartsAtItsOldestGeneration() throws {
        let directory = try VibeFixture.write(VibeFixture.pruned(), under: root)
        guard case .session(_, let points) = VibeSessionStore.read(directory) else { return XCTFail("not read") }
        XCTAssertEqual(points.map(\.total), [751_847, 751_847, 751_847, 797_997, 797_997])
        XCTAssertEqual(milliseconds(points.first), 1_793_978_821_829, "generation 323, a second before journal 324 opens")
    }

    func testASessionWithNoTotalHasNoPoints() throws {
        let directory = try VibeFixture.write(VibeFixture.noTotal(), under: root)
        XCTAssertEqual(
            VibeSessionStore.read(directory),
            .session(VibeSessionStore.Meta(
                title: "Fixture title", workingDirectory: "/tmp/Vibe Fixtures/probe",
                activeModel: "mistral-medium-3.5", modelName: "mistral-vibe-cli-latest"
            ), [])
        )
    }

    func testMetaNamesTheTitleTheFolderAndBothModelIDs() throws {
        let directory = try VibeFixture.write(VibeFixture.glm(), under: root)
        guard case .session(let meta, _) = VibeSessionStore.read(directory) else { return XCTFail("not read") }
        XCTAssertEqual(meta, VibeSessionStore.Meta(
            title: "Fixture title", workingDirectory: "/tmp/Vibe Fixtures/probe",
            activeModel: "glm-5-3", modelName: "zai-glm-5-3"
        ))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("meta.json"))
        guard case .session(let bare, let points) = VibeSessionStore.read(directory) else { return XCTFail("not read") }
        XCTAssertEqual(bare, VibeSessionStore.Meta(), "no meta.json: the tokens still count, unnamed")
        XCTAssertEqual(points.map(\.total), [6_866, 6_866])
    }

    func testAnotherStoreFormatOrNoneIsSkippedWhole() throws {
        var future = VibeFixture.whole()
        future.format = "mistral.vibe.unified-session-store/v2"
        let directory = try VibeFixture.write(future, under: root)
        XCTAssertEqual(VibeSessionStore.read(directory), .unknownStore("mistral.vibe.unified-session-store/v2"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("CURRENT"))
        XCTAssertEqual(VibeSessionStore.read(directory), .unknownStore(nil))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("CURRENT"))
        XCTAssertEqual(VibeSessionStore.read(directory), .unknownStore(nil))
        XCTAssertNil(VibeSessionStore.mark(of: directory), "no CURRENT: not a session")
    }

    func testTheMarkMovesWhenAJournalGrows() throws {
        let session = VibeFixture.repeated()
        let directory = try VibeFixture.write(session, under: root)
        let before = try XCTUnwrap(VibeSessionStore.mark(of: directory))
        XCTAssertEqual(before.files, 6, "CURRENT, meta.json, two generations, two journal segments")
        XCTAssertEqual(VibeSessionStore.mark(of: directory), before, "nothing moved, the same mark")
        let journal = directory.appendingPathComponent("journal/\(VibeFixture.sequenceName(14)).jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        let step = VibeFixture.envelope(
            session, sequence: 15, usage: VibeFixture.Usage(input: 7_000, cached: 3_072, output: 70), ms: 1_793_977_700_000
        )
        try handle.write(contentsOf: Data((step + "\n").utf8))
        try handle.close()
        XCTAssertNotEqual(VibeSessionStore.mark(of: directory), before)
    }

    func testAHalfWrittenLastLineWaitsForTheNextRead() {
        let session = VibeFixture.repeated()
        let written = VibeFixture.envelope(
            session, sequence: 7, usage: VibeFixture.Usage(input: 6_930, cached: 3_072, output: 67), ms: 1_793_977_627_409
        )
        let writing = VibeFixture.envelope(
            session, sequence: 9, usage: VibeFixture.Usage(input: 7_500, cached: 3_072, output: 80), ms: 1_793_977_627_414
        )
        let text = written + "\n" + String(writing.prefix(writing.count - 40))
        XCTAssertEqual(VibeSessionStore.points(journal: Data(text.utf8)).map(\.total), [6_997])
    }

    func testAnExtremeOrNegativeCounterNeitherTrapsNorGoesBelowZero() throws {
        var session = VibeFixture.whole()
        let huge = VibeFixture.envelope(
            session, sequence: 7, usage: VibeFixture.Usage(input: Int.max, cached: 0, output: 1), ms: 1_793_977_712_751
        )
        let negative = VibeFixture.envelope(
            session, sequence: 9, usage: VibeFixture.Usage(input: -5, cached: -1, output: -3), ms: 1_793_977_712_759
        )
        let points = VibeSessionStore.points(journal: Data((huge + "\n" + negative + "\n").utf8))
        XCTAssertEqual(points.map(\.total), [Int.max, 0], "saturated, and clamped at zero")
        XCTAssertEqual(points.last.map { [$0.input, $0.cached, $0.output] }, [0, 0, 0])
        session.journals = [1: [huge, negative], 74: []]
        let directory = try VibeFixture.write(session, under: root)
        guard case .session(_, let read) = VibeSessionStore.read(directory) else { return XCTFail("not read") }
        XCTAssertEqual(read.map(\.total), [Int.max, 0, 66_132], "sorting past Int.max does not trap")
    }
}
