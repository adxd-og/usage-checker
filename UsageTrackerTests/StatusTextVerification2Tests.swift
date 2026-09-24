import XCTest
@testable import Omelette

/// Independent verification of `StatusText.costParts`' API-equivalent suffix,
/// derived from `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design
/// "Agents, CLI, scripts (report C)" and the verification report's item 5 ("same
/// service with apiEquivalent true vs false differ"), not from `StatusTextTests`.
/// Focus: `true` vs `false` vs `nil` side by side on one service, that the suffix
/// never appears twice on a two-part line, and that a service with nothing to show
/// produces no dangling suffix.
final class StatusTextVerification2Tests: XCTestCase {
    private func service(
        todayCost: Double? = nil, weekCost: Double? = nil, apiEquivalent: Bool? = nil
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
            plan: nil, windows: [], todayCost: todayCost, weekCost: weekCost,
            todayTokens: nil, apiEquivalent: apiEquivalent
        )
    }

    /// The same numbers, three ways to flag them: the suffix appears only for `true`.
    func testTrueFalseAndNilProduceThreeDifferentLines() {
        let trueLine = StatusText.costParts(service(todayCost: 4.2, apiEquivalent: true))
        let falseLine = StatusText.costParts(service(todayCost: 4.2, apiEquivalent: false))
        let nilLine = StatusText.costParts(service(todayCost: 4.2, apiEquivalent: nil))

        XCTAssertEqual(trueLine, ["$4.20 today (API-equivalent)"])
        XCTAssertEqual(falseLine, ["$4.20 today"])
        XCTAssertEqual(nilLine, ["$4.20 today"])
        XCTAssertEqual(falseLine, nilLine, "an explicit false and an absent flag must read identically")
    }

    /// With both a today and a week figure, the suffix rides only the last part —
    /// never both, and never neither.
    func testTheSuffixAppearsExactlyOnceAcrossBothFigures() {
        let parts = StatusText.costParts(service(todayCost: 4.2, weekCost: 31.7, apiEquivalent: true))
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], "$4.20 today", "the suffix is not on the first part")
        XCTAssertEqual(parts[1], "$31.70 this week (API-equivalent)")
        let occurrences = parts.joined().components(separatedBy: "API-equivalent").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    /// A subscription that spent nothing today or this week has no dollar parts at
    /// all — the suffix must never appear on its own with nothing to qualify.
    func testNoSpendMeansNoPartsEvenWhenFlagged() {
        XCTAssertEqual(StatusText.costParts(service(todayCost: 0, weekCost: 0, apiEquivalent: true)), [])
        XCTAssertEqual(StatusText.costParts(service(apiEquivalent: true)), [])
    }
}
