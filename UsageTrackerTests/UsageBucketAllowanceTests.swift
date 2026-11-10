import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Windows: a window can carry the dollar allowance it is
/// counted in ("$17.88 of $300"). Unlike a prepaid credit pool it stays a limit: it leads the
/// headline, reaches the widget and keeps its percent in `status.json`, which carries no dollars
/// for it. The allowance survives `last-known.json`, and a file written before it still opens.
final class UsageBucketAllowanceTests: XCTestCase {
    private let allowance = CreditPool(usedDollars: 17.88, limitDollars: 300)

    private func vibe(allowance: CreditPool? = CreditPool(usedDollars: 17.88, limitDollars: 300)) -> UsageBucket {
        Fixture.bucket(id: "mistral_vibe", label: "Vibe", percent: 5.96, kind: .weekly, allowance: allowance)
    }

    func testAWindowWithAnAllowanceIsStillALimitNotACreditPool() {
        let bucket = vibe()
        XCTAssertEqual(bucket.allowance, allowance)
        XCTAssertNil(bucket.credit)
        XCTAssertFalse(bucket.isCreditPool)
        XCTAssertFalse(bucket.isBonusPool)
        let service = Fixture.snapshot(id: "mistral", buckets: [bucket])
        XCTAssertEqual(service.percentWindows.map(\.id), ["mistral_vibe"])
        XCTAssertTrue(service.creditPools.isEmpty)
        XCTAssertEqual(service.headlinePercent, 5.96)
    }

    func testTheAllowanceSurvivesTheLastKnownFile() throws {
        let data = try JSONEncoder().encode(vibe())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let written = try XCTUnwrap(object["allowance"] as? [String: Any])
        XCTAssertEqual(written["usedDollars"] as? Double, 17.88)
        XCTAssertEqual(written["limitDollars"] as? Double, 300)
        XCTAssertEqual(try JSONDecoder().decode(UsageBucket.self, from: data), vibe())
    }

    func testAWindowWithoutAnAllowanceWritesNoKeyAndAnOlderFileStillOpens() throws {
        let data = try JSONEncoder().encode(vibe(allowance: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["allowance"])
        let older = Data(#"{"id":"seven_day","label":"All models","utilization":18,"resetsAt":0,"kind":"weekly"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(UsageBucket.self, from: older).allowance)
    }

    func testStatusJSONKeepsThePercentAndCarriesNoDollarsForAnAllowance() throws {
        let now = Date(timeIntervalSince1970: 1_794_312_000)
        let service = Fixture.snapshot(id: "mistral", displayName: "Mistral", buckets: [vibe()], at: now)
        let file = StatusFileWriter.build(services: [service], costs: [:], agents: .none, now: now)
        let window = try XCTUnwrap(file.services.first?.windows.first)
        XCTAssertEqual(window.percent, 5.96)
        XCTAssertNil(window.usedDollars, "dollars in the file would read as a credit pool to the CLI")
        XCTAssertNil(window.limitDollars)
        XCTAssertFalse(window.isCreditPool)
    }

    func testTheWidgetKeepsAWindowWithAnAllowance() {
        let services = WidgetBridge.widgetServices(from: [Fixture.snapshot(id: "mistral", buckets: [vibe()])])
        XCTAssertEqual(services.first?.buckets.map(\.id), ["mistral_vibe"])
    }
}
