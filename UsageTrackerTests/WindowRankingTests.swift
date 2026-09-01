import XCTest
import SwiftUI
@testable import Omelette

final class WindowRankingTests: XCTestCase {
    // MARK: usageStatusColor
    func testStatusColorIsGreenWhenComfortable() {
        XCTAssertEqual(usageStatusColor(0), .green)
        XCTAssertEqual(usageStatusColor(69.9), .green)
    }
    func testStatusColorIsOrangeFrom70() {
        XCTAssertEqual(usageStatusColor(70), .orange)
        XCTAssertEqual(usageStatusColor(89.9), .orange)
    }
    func testStatusColorIsRedFrom90() {
        XCTAssertEqual(usageStatusColor(90), .red)
        XCTAssertEqual(usageStatusColor(150), .red)
    }

    // MARK: hero
    private func claude(_ buckets: [UsageBucket], extra: ExtraUsage? = nil) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: buckets, extraUsage: extra)
    }
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 37, kind: .session)
    private let weekly  = Fixture.bucket(id: "seven_day", label: "All models", percent: 52, kind: .weekly)
    private let opus    = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 90, kind: .modelSpecific)
    private let promo   = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 99, kind: .other)

    func testHeroIsWorstCoreWindowIgnoringModelScoped() {
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([session, weekly, opus]))?.id, "seven_day")
    }
    func testHeroTieGoesToFirstInAPIOrder() {
        let a = Fixture.bucket(id: "five_hour", percent: 0, kind: .session)
        let b = Fixture.bucket(id: "seven_day", percent: 0, kind: .weekly)
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([a, b]))?.id, "five_hour")
    }
    func testHeroIgnoresPromotionalUnlessAlone() {
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([session, promo]))?.id, "five_hour")
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([promo]))?.id, "seven_day_promotional")
    }
    func testHeroFallsBackToModelScopedWhenNothingElse() {
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([opus]))?.id, "seven_day_opus")
    }
    func testExtraUsageCompetesWhenEnabled() {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 40, utilization: 80)
        let hero = WindowRanking.heroBucket(for: claude([session, weekly], extra: extra))
        XCTAssertEqual(hero?.id, "claude_extra_usage")
        XCTAssertEqual(hero?.label, "Extra usage credits")
        XCTAssertEqual(hero?.kind, .other)
    }
    func testExtraUsageIgnoredWhenDisabled() {
        let extra = ExtraUsage(isEnabled: false, monthlyLimit: 50, usedCredits: 40, utilization: 80)
        XCTAssertEqual(WindowRanking.heroBucket(for: claude([session, weekly], extra: extra))?.id, "seven_day")
    }
    func testHeroNilWithoutWindows() {
        XCTAssertNil(WindowRanking.heroBucket(for: claude([])))
    }

    // MARK: secondary
    func testSecondaryPrefersAllModelsWeeklyWhenNotHero() {
        let hotSession = Fixture.bucket(id: "five_hour", label: "Current session", percent: 60, kind: .session)
        XCTAssertEqual(WindowRanking.secondaryBucket(for: claude([hotSession, weekly, opus]))?.id, "seven_day")
    }
    func testSecondaryIsNextWorstCoreWhenWeeklyIsHero() {
        XCTAssertEqual(WindowRanking.secondaryBucket(for: claude([session, weekly, opus]))?.id, "five_hour")
    }
    func testSecondaryNilWithSingleWindow() {
        XCTAssertNil(WindowRanking.secondaryBucket(for: claude([session])))
    }

    // MARK: labels
    func testShortWindowLabel() {
        XCTAssertEqual(WindowRanking.shortWindowLabel("All models"), "All")
        XCTAssertEqual(WindowRanking.shortWindowLabel("Opus only"), "Opus")
        XCTAssertEqual(WindowRanking.shortWindowLabel("Fable only"), "Fable")
        XCTAssertEqual(WindowRanking.shortWindowLabel("Current session"), "Current session")
    }

    // MARK: tabs
    func testResolveTabDefaultsToAll() {
        let services = [Fixture.snapshot(id: "claude"), Fixture.snapshot(id: "codex")]
        XCTAssertEqual(WindowRanking.resolveTab(stored: "", displayed: services), "all")
        XCTAssertEqual(WindowRanking.resolveTab(stored: "grok", displayed: services), "all")
        XCTAssertEqual(WindowRanking.resolveTab(stored: "all", displayed: services), "all")
        XCTAssertEqual(WindowRanking.resolveTab(stored: "codex", displayed: services), "codex")
    }

    // MARK: remaining
    func testRemainingText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(WindowRanking.remainingText(until: now.addingTimeInterval(2 * 3600 + 15 * 60), now: now), "2h 15m left")
        XCTAssertEqual(WindowRanking.remainingText(until: now.addingTimeInterval(-5), now: now), "resets now")
        XCTAssertNil(WindowRanking.remainingText(until: .distantFuture, now: now))
    }
}
