import XCTest
@testable import Omelette

/// Tester's verification of the pet's alert after the fix round (whole-branch review of 4.0,
/// rulings 2 and 10): a model-specific window does not alarm unless it is all a provider has, and
/// a provider switched off stops alarming at once.
final class PetAlertSelectorModelWindowVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_022_480)
    private let all: Set<String> = ["claude", "codex", "antigravity", "grok"]

    private func model(_ percent: Double, id: String) -> UsageBucket {
        Fixture.bucket(id: id, label: id, percent: percent, kind: .modelSpecific)
    }

    private func service(_ id: String, _ buckets: [UsageBucket]) -> ServiceSnapshot {
        Fixture.snapshot(id: id, displayName: id.capitalized, buckets: buckets, state: .ok, at: now)
    }

    /// The rule is about one provider's own windows: another provider's core window does not
    /// make this one's per-model windows secondary.
    func testAProviderWithOnlyModelWindowsStillAlarmsBesideAnotherProvidersCoreWindow() {
        let services = [
            service("claude", [Fixture.bucket(id: "five_hour", label: "Current session", percent: 20, kind: .session)]),
            service("antigravity", [model(99, id: "antigravity_model-argon")]),
        ]
        let alert = PetAlertSelector.alert(in: services, enabledIDs: all)
        XCTAssertEqual(alert?.serviceID, "antigravity")
        XCTAssertEqual(alert?.bucket.id, "antigravity_model-argon")
    }

    /// With model windows all there is, they rank as any windows do: the fullest wins.
    func testSeveralModelWindowsAloneRankByUsedPercent() {
        let alert = PetAlertSelector.alert(
            in: [service("antigravity", [model(93, id: "a"), model(97, id: "b"), model(91, id: "c")])],
            enabledIDs: all
        )
        XCTAssertEqual(alert?.bucket.id, "b")
    }

    /// A model window is never *the* alert beside a core one, even when the core one is the
    /// only thing past the threshold and the model one is fuller, and not when it is below.
    func testBesideACoreWindowNoModelWindowIsEverChosen() {
        for core in [0.0, 50, 89.99, 90, 100] {
            let alert = PetAlertSelector.alert(
                in: [service("claude", [model(100, id: "seven_day_fable"), Fixture.bucket(id: "seven_day", percent: core, kind: .weekly)])],
                enabledIDs: all
            )
            XCTAssertEqual(alert?.bucket.id, core >= 90 ? "seven_day" : nil, "core at \(core)")
        }
    }

    /// A window of no named kind is a window the provider has beside its model ones.
    func testAnOtherKindWindowIsNotAModelWindow() {
        let other = Fixture.bucket(id: "claude_other", label: "Other", percent: 20, kind: .other)
        XCTAssertNil(PetAlertSelector.alert(in: [service("claude", [model(100, id: "seven_day_fable"), other])], enabledIDs: all))
    }

    // MARK: - Off means off

    func testTheSwitchedOnSetCrossedWithEverySwitchAndThePollsAdminKey() {
        for mask in 0..<16 {
            let claude = mask & 1 != 0, codex = mask & 2 != 0, antigravity = mask & 4 != 0, grok = mask & 8 != 0
            var want: Set<String> = []
            if claude { want.insert("claude") }
            if codex { want.insert("codex") }
            if antigravity { want.insert("antigravity") }
            if grok { want.insert("grok") }
            for admin in [false, true] {
                // The poll's own list never decides the four switches, only whether it saw an admin key.
                for polled: Set<String> in [[], ["claude", "codex", "antigravity", "grok"], ["grok"]] {
                    let ids = AppState.switchedOnIDs(
                        polledIDs: polled.union(admin ? ["anthropic-admin"] : []),
                        claudeEnabled: claude, codexEnabled: codex, antigravityEnabled: antigravity, grokEnabled: grok
                    )
                    XCTAssertEqual(ids, want.union(admin ? ["anthropic-admin"] : []), "mask \(mask), admin \(admin), polled \(polled)")
                }
            }
            XCTAssertNil(AppState.switchedOnIDs(
                polledIDs: nil, claudeEnabled: claude, codexEnabled: codex, antigravityEnabled: antigravity, grokEnabled: grok
            ), "before the first poll nothing limits")
        }
    }

    /// A provider that went off drops out at once, a provider still on keeps alarming, and the
    /// one that is fullest among the rest wins.
    func testSwitchingTheFullestProviderOffHandsTheAlertToTheNextOne() {
        let services = [
            service("claude", [Fixture.bucket(id: "seven_day", percent: 93, kind: .weekly)]),
            service("codex", [Fixture.bucket(id: "codex_primary", percent: 99, kind: .session)]),
        ]
        let polled: Set<String> = ["claude", "codex"]
        func alert(codex: Bool) -> String? {
            PetAlertSelector.alert(
                in: services,
                enabledIDs: AppState.switchedOnIDs(
                    polledIDs: polled, claudeEnabled: true, codexEnabled: codex, antigravityEnabled: false, grokEnabled: false
                )
            )?.serviceID
        }
        XCTAssertEqual(alert(codex: true), "codex")
        XCTAssertEqual(alert(codex: false), "claude")
    }
}
