import XCTest
@testable import Omelette

/// The header of `Main.dc.html` ("Updated just now") and `Popover-Claude.dc.html`
/// ("Claude Max 20x · Updated 7s ago"), and the tile's plan line: the plan on its own
/// line without the provider's name said twice.
final class PopoverCopyTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private func after(_ seconds: TimeInterval) -> Date { fetchedAt.addingTimeInterval(seconds) }

    func testThePlanLineDropsTheProvidersNameAndNeverRepeatsIt() {
        XCTAssertEqual(PopoverCopy.planLine(plan: "Max 20x", displayName: "Claude"), "Max 20x")
        XCTAssertEqual(PopoverCopy.planLine(plan: "Codex Plus", displayName: "Codex"), "Plus")
        XCTAssertEqual(PopoverCopy.planLine(plan: "SuperGrok", displayName: "Grok"), "SuperGrok")
        XCTAssertNil(PopoverCopy.planLine(plan: "Antigravity", displayName: "Antigravity"))
        XCTAssertNil(PopoverCopy.planLine(plan: nil, displayName: "Claude"))
        XCTAssertNil(PopoverCopy.planLine(plan: "  ", displayName: "Claude"))
    }

    func testTheUpdateTimeReadsUpdatedJustNowThenCounts() {
        XCTAssertEqual(PopoverCopy.updatedText(fetchedAt: Date(timeIntervalSince1970: 0), now: fetchedAt), "Never updated")
        XCTAssertEqual(PopoverCopy.updatedText(fetchedAt: fetchedAt, now: after(3)), "Updated just now")
        XCTAssertEqual(PopoverCopy.updatedText(fetchedAt: fetchedAt, now: after(7)), "Updated 7s ago")
        XCTAssertEqual(PopoverCopy.updatedText(fetchedAt: fetchedAt, now: after(125)), "Updated 2m ago")
        XCTAssertEqual(PopoverCopy.updatedText(fetchedAt: fetchedAt, now: after(7300)), "Updated 2h ago")
        XCTAssertEqual(PopoverCopy.updatedText(fetchedAt: fetchedAt, now: after(-30)), "Updated just now",
                       "a clock that stepped back is not a reading from the future")
    }

    func testTheAllTabSaysOnlyWhenItUpdated() {
        XCTAssertEqual(PopoverCopy.metaLine(service: nil, fetchedAt: fetchedAt, now: after(0)), "Updated just now")
    }

    func testAProviderTabNamesTheProviderAndItsPlanFirst() {
        let claude = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Max 20x")
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", plan: "Codex Plus")
        let grok = Fixture.snapshot(id: "grok", displayName: "Grok", plan: nil)
        XCTAssertEqual(PopoverCopy.metaLine(service: claude, fetchedAt: fetchedAt, now: after(7)), "Claude Max 20x · Updated 7s ago")
        XCTAssertEqual(PopoverCopy.metaLine(service: codex, fetchedAt: fetchedAt, now: after(7)), "Codex Plus · Updated 7s ago")
        XCTAssertEqual(PopoverCopy.metaLine(service: grok, fetchedAt: fetchedAt, now: after(7)), "Grok · Updated 7s ago")
    }
}
