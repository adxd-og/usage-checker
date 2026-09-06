import XCTest
@testable import Omelette

/// Independent verification of two things from the audit that are easy to get subtly
/// wrong: (1) commit b67353e ("Claude: a turn's dollars are the ones stored with it") —
/// a turn's `cost` must keep reading the rate that was live when it was *parsed*, not
/// whatever `ModelPricing` says right now, all the way through the aggregator, not just
/// on a hand-built `CLITurn`; and (2) commit bea2cc5 ("Pricing: bring the offline table
/// up to the current models.dev rates") — the static fallback table has to still match
/// the models.dev numbers this machine has actually cached
/// (`~/Library/Application Support/UsageTracker/models-dev-pricing-v3.json`), read
/// fresh here rather than trusted from a comment. Written without reading
/// `JSONLAggregatorTests`, `JSONLAggregatorVerificationTests` or `ModelPricingTableTests`.
final class StoredCostAndPricingTableVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredCostAndPricingTableVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func line(id: String, minutesAgo: Double, model: String, input: Int, output: Int) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0}}}
        """
    }

    private func write(_ lines: [String], project: String = "proj") throws {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    }

    // MARK: - Stored dollars survive a live price change, end to end through the aggregator

    func testAnIngestedTurnsCostDoesNotMoveWhenThePriceTableChangesAfterwards() async throws {
        // No dynamic price active at ingest time — the turn prices from the static
        // table for "claude-sonnet-5" ($2/$10 per M).
        try write([line(id: "msg_pinned", minutesAgo: 10, model: "claude-sonnet-5", input: 1_000_000, output: 1_000_000)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let before = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(before.cost, 12, accuracy: 1e-9, "$2 of input + $10 of output at the static rate")

        // A live rate change lands — as a models.dev refresh would do mid-session.
        ModelPricing.updateDynamic([
            "claude-sonnet-5": ModelPrice(inputPerM: 999, outputPerM: 999, cacheReadPerM: 999, cacheCreate5mPerM: 999, cacheCreate1hPerM: 999),
        ])

        // Re-querying the SAME aggregator, with no re-ingest, must return the same
        // dollars: the turn already carries its own stored `tokens.cost`.
        let after = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(after.cost, 12, accuracy: 1e-9, "the stored figure, unmoved by the new rate")
        XCTAssertEqual(try XCTUnwrap(after.breakdown.cost).total, 12, accuracy: 1e-9)

        // A FRESH aggregator that parses the same file now, with the new rate live,
        // must price the turn at the new rate — proving the difference is about when
        // the turn was parsed, not a test that can't see the rate change at all.
        let fresh = JSONLAggregator(rootURL: root, cacheURL: nil)
        await fresh.refresh()
        let freshUsage = await fresh.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(freshUsage.cost, 999 + 999, accuracy: 1e-9, "a turn parsed under the new rate prices at it")
        XCTAssertNotEqual(freshUsage.cost, after.cost, accuracy: 1e-9)
    }

    func testATurnWithNoStoredSplitPricesFromWhicheverTableIsCurrentlyLive() throws {
        // `tokens.cost` stays nil (the type allows a turn with no split at all); `cost`
        // must fall back to `ModelPricing.price(for:)`, and must see a live rate change
        // immediately since there is no stored figure to protect.
        let turn = CLITurn(
            id: "msg_no_split", timestamp: now, model: "claude-haiku-4-5",
            tokens: TokenBreakdown(input: 2_000_000, output: 1_000_000),
            projectSlug: "proj"
        )
        XCTAssertEqual(turn.cost, 7, accuracy: 1e-9, "$1 x 2 of input + $5 x 1 of output at the static rate")

        ModelPricing.updateDynamic([
            "claude-haiku-4-5": ModelPrice(inputPerM: 100, outputPerM: 100, cacheReadPerM: 0, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0),
        ])
        XCTAssertEqual(turn.cost, 300, accuracy: 1e-9, "no stored split, so the live rate applies immediately")
    }

    // MARK: - Static table vs. the models.dev snapshot actually cached on this machine

    private struct DiskModelPrice: Decodable {
        let inputPerM: Double
        let outputPerM: Double
        let cacheReadPerM: Double
        let cacheCreate5mPerM: Double
        let cacheCreate1hPerM: Double
    }

    private struct DiskCache: Decodable {
        let prices: [String: DiskModelPrice]
    }

    /// The same location `ModelsDevPricing.cacheURL` writes to — read-only here.
    private func readDiskCache() throws -> DiskCache? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent("UsageTracker/models-dev-pricing-v3.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(DiskCache.self, from: data)
    }

    func testTheStaticFallbackTableMatchesTheModelsDevSnapshotCachedOnThisMachine() throws {
        guard let cache = try readDiskCache() else {
            throw XCTSkip("no models-dev-pricing-v3.json cached on this machine to compare against")
        }
        // Every row the spec calls out by name. A row this machine's cache doesn't
        // carry (e.g. a fictional "Mythos" line models.dev has never priced) is
        // reported, not silently skipped and not failed — a missing external fixture
        // is not a code defect.
        let namedRows = [
            "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
            "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5",
            "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
            "claude-sonnet-4-6", "claude-sonnet-4-5",
        ]
        var checked = 0
        var missingFromDisk: [String] = []
        ModelPricing.updateDynamic([:]) // compare the hardcoded table, not a live rate
        for id in namedRows {
            guard let disk = cache.prices[id] else {
                missingFromDisk.append(id)
                continue
            }
            let table = ModelPricing.table[id]
            let live = ModelPricing.price(for: id)
            XCTAssertNotNil(table, "\(id) is named by the spec but has no row in ModelPricing.table")
            let p = table ?? live
            XCTAssertEqual(p.inputPerM, disk.inputPerM, accuracy: 1e-9, "\(id) inputPerM")
            XCTAssertEqual(p.outputPerM, disk.outputPerM, accuracy: 1e-9, "\(id) outputPerM")
            XCTAssertEqual(p.cacheReadPerM, disk.cacheReadPerM, accuracy: 1e-9, "\(id) cacheReadPerM")
            XCTAssertEqual(p.cacheCreate5mPerM, disk.cacheCreate5mPerM, accuracy: 1e-9, "\(id) cacheCreate5mPerM")
            XCTAssertEqual(p.cacheCreate1hPerM, disk.cacheCreate1hPerM, accuracy: 1e-9, "\(id) cacheCreate1hPerM")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "at least one named row must actually be comparable, or this test proves nothing")
        if !missingFromDisk.isEmpty {
            print("[verification] not present in the cached models.dev snapshot, unverified: \(missingFromDisk)")
        }
    }
}
