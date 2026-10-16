import XCTest
@testable import Omelette

/// Limit analytics' turn query on the cost-log protocol: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Packages 1
/// (`turnCosts(from:to:)`). A provider whose log names no chat (the Grok CLI writes
/// per-turn costs and nothing that says which conversation they belonged to) answers
/// the protocol's default.
final class TurnCostLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnCostLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAProviderWhoseLogNamesNoChatAnswersNoTurns() async {
        let grok: any CostLogAggregating = GrokUsageAggregator(rootURL: root)
        let log = await grok.turnCosts(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1_788_696_000)
        )
        XCTAssertEqual(log, .empty)
        XCTAssertTrue(log.turns.isEmpty)
        XCTAssertTrue(log.titles.isEmpty)
    }
}
