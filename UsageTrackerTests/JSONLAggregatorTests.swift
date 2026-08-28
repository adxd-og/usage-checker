import XCTest
@testable import Omelette

/// Fixture logs mimic what Claude Code writes to `~/.claude/projects/<slug>/<uuid>.jsonl`.
/// Costs are asserted in dollars against the static `ModelPricing` table, which is what
/// the app uses offline — `ModelsDevPricing` never runs in this target, so nothing
/// network-dependent can move these numbers.
final class JSONLAggregatorTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let betaSlug = "-Users-tester-Projects-beta"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture writing

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func line(id: String, minutesAgo: Double, model: String, input: Int, output: Int = 0) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    private func write(_ lines: [String], project: String, file: String = "session.jsonl") throws {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Two projects, four distinct turns, one duplicated log line, one turn well
    /// outside the two-hour window under test.
    private func writeStandardFixture() throws {
        let a1 = line(id: "msg_a1", minutesAgo: 90, model: "claude-sonnet-4-5", input: 1_000_000)
        try write([
            a1,
            line(id: "msg_a2", minutesAgo: 60, model: "claude-opus-4-5", input: 1_000_000),
            a1, // Claude Code logs the same response several times; it must count once.
            line(id: "msg_old", minutesAgo: 300, model: "claude-sonnet-4-5", input: 1_000_000),
        ], project: alphaSlug)
        try write([
            line(id: "msg_b1", minutesAgo: 30, model: "claude-sonnet-4-5", input: 500_000),
        ], project: betaSlug)
    }

    private func loadedAggregator() async throws -> JSONLAggregator {
        try writeStandardFixture()
        let aggregator = JSONLAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    // MARK: - Pricing assumptions these tests are written against

    func testStaticPricingMatchesTheAssumedRates() {
        // If these move, the dollar figures below are stale — fail here rather than
        // somewhere less obvious.
        XCTAssertEqual(ModelPricing.table["claude-sonnet-4-5"]?.inputPerM, 3)
        XCTAssertEqual(ModelPricing.table["claude-opus-4-5"]?.inputPerM, 5)
    }

    // MARK: - usage(from:to:)

    func testWindowSumsOnlyTheTurnsInsideIt() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.turns, 3, "the duplicate and the 5-hour-old turn must not count")
        XCTAssertEqual(usage.tokens, 2_500_000)
        XCTAssertEqual(usage.cost, 9.5, accuracy: 0.0001) // $3.00 + $5.00 + $1.50
        XCTAssertFalse(usage.isEmpty)
    }

    func testWindowRanksProjectsByCost() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.projects.map(\.slug), [alphaSlug, betaSlug])
        XCTAssertEqual(usage.projects[0].totalCost, 8.0, accuracy: 0.0001)
        XCTAssertEqual(usage.projects[0].turns, 2)
        XCTAssertEqual(usage.projects[1].totalCost, 1.5, accuracy: 0.0001)
        XCTAssertEqual(usage.projects[1].turns, 1)
    }

    func testWindowRanksModelsByCost() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.models.map { $0.model }, ["Opus 4.5", "Sonnet 4.5"])
        XCTAssertEqual(usage.models[0].cost, 5.0, accuracy: 0.0001)
        XCTAssertEqual(usage.models[1].cost, 4.5, accuracy: 0.0001) // both Sonnet turns
        XCTAssertEqual(usage.models[1].tokens, 1_500_000)
    }

    func testAWindowWithNothingInItIsEmpty() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(
            from: now.addingTimeInterval(-4 * 3600),
            to: now.addingTimeInterval(-3 * 3600)
        )

        XCTAssertTrue(usage.isEmpty)
        XCTAssertEqual(usage.turns, 0)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertTrue(usage.projects.isEmpty)
        XCTAssertTrue(usage.models.isEmpty)
    }

    func testARescanDoesNotDoubleCount() async throws {
        let aggregator = try await loadedAggregator()
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.turns, 3)
        XCTAssertEqual(usage.cost, 9.5, accuracy: 0.0001)
    }

    // MARK: - breakdown()

    func testBreakdownCoversTheWholeWeekAndRanksProjects() async throws {
        let aggregator = try await loadedAggregator()
        let breakdown = await aggregator.breakdown()

        // Everything in the fixture is inside the last 24 hours, so week and month agree.
        XCTAssertEqual(breakdown.weekCost, 12.5, accuracy: 0.0001) // adds the 5-hour-old $3.00
        XCTAssertEqual(breakdown.monthCost, 12.5, accuracy: 0.0001)
        XCTAssertEqual(breakdown.projectsWeek.map(\.slug), [alphaSlug, betaSlug])
        XCTAssertEqual(breakdown.projectsWeek[0].totalCost, 11.0, accuracy: 0.0001)
        XCTAssertEqual(breakdown.projectsWeek[0].turns, 3)
        XCTAssertEqual(breakdown.projectsWeek[1].totalCost, 1.5, accuracy: 0.0001)
    }

    func testAnEmptyLogRootProducesNothing() async throws {
        let aggregator = JSONLAggregator(rootURL: root)
        await aggregator.refresh()
        let breakdown = await aggregator.breakdown()

        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(breakdown.weekCost, 0)
        XCTAssertTrue(breakdown.projectsWeek.isEmpty)
        XCTAssertTrue(usage.isEmpty)
    }

    func testNonAssistantAndSyntheticLinesAreSkipped() async throws {
        try write([
            #"{"type":"user","timestamp":"\#(Self.iso.string(from: now))","message":{"id":"msg_u","role":"user"}}"#,
            line(id: "msg_synthetic", minutesAgo: 10, model: "<synthetic>", input: 1_000_000),
            line(id: "msg_real", minutesAgo: 10, model: "claude-sonnet-4-5", input: 1_000_000),
        ], project: alphaSlug)
        let aggregator = JSONLAggregator(rootURL: root)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.cost, 3.0, accuracy: 0.0001)
    }
}
