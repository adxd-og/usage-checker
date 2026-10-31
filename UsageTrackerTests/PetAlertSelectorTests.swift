import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Alert selector": eligible readings are live (not
/// retained) windows of enabled providers, excluding prepaid and promotional pools; threshold
/// 90 % used (≥ 90.0); the highest used percent wins, ties by provider display order then the
/// shorter window; it is not the tile hero (a 92 % week wins over a 40 % session).
final class PetAlertSelectorTests: XCTestCase {
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)
    private let all: Set<String> = ["claude", "codex", "antigravity", "grok"]

    private func session(_ percent: Double, id: String = "five_hour") -> UsageBucket {
        Fixture.bucket(id: id, label: "Current session", percent: percent, kind: .session)
    }

    private func week(_ percent: Double, id: String = "seven_day", label: String = "All models") -> UsageBucket {
        Fixture.bucket(id: id, label: label, percent: percent, kind: .weekly)
    }

    private func service(_ id: String, _ buckets: [UsageBucket], state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: id, displayName: id.capitalized, buckets: buckets, state: state, at: now)
    }

    func testBelow90PercentNothingFires() {
        let services = [service("claude", [session(89.99), week(60)])]
        XCTAssertNil(PetAlertSelector.alert(in: services, enabledIDs: all))
    }

    func testAWindowAtExactly90PercentFires() {
        let alert = PetAlertSelector.alert(in: [service("claude", [session(90)])], enabledIDs: all)
        XCTAssertEqual(alert?.bucket.id, "five_hour")
        XCTAssertEqual(alert?.usedPercent, 90)
    }

    func testANearlyFullWeekWinsOverTheSessionTheTileLeadsWith() {
        let claude = service("claude", [session(40), week(92)])
        XCTAssertEqual(WindowRanking.tileHero(for: claude)?.id, "five_hour", "the tile leads with the session")
        XCTAssertEqual(
            PetAlertSelector.alert(in: [claude], enabledIDs: all),
            PetAlert(serviceID: "claude", serviceName: "Claude", bucket: week(92))
        )
    }

    func testTheHighestUsedPercentWinsAcrossProviders() {
        let services = [service("claude", [week(92)]), service("codex", [session(95, id: "codex_primary")])]
        XCTAssertEqual(PetAlertSelector.alert(in: services, enabledIDs: all)?.serviceID, "codex")
    }

    func testATieGoesToTheProviderShownFirst() {
        let services = [
            service("codex", [week(93, id: "codex_secondary", label: "Weekly")]),
            service("claude", [session(93)]),
        ]
        XCTAssertEqual(PetAlertSelector.alert(in: services, enabledIDs: all)?.serviceID, "codex")
    }

    func testATieWithinAProviderGoesToTheShorterWindow() {
        let alert = PetAlertSelector.alert(in: [service("claude", [week(93), session(93)])], enabledIDs: all)
        XCTAssertEqual(alert?.bucket.id, "five_hour")
    }

    func testAWindowOfUnknownLengthLosesATieAndEqualWindowsKeepTheProvidersOrder() {
        let unknown = Fixture.bucket(id: "claude_other", label: "Other", percent: 94, kind: .other)
        let first = week(94, id: "seven_day_first")
        let second = week(94, id: "seven_day_second")
        XCTAssertNil(unknown.windowDuration)
        let alert = PetAlertSelector.alert(in: [service("claude", [unknown, first, second])], enabledIDs: all)
        XCTAssertEqual(alert?.bucket.id, "seven_day_first")
    }

    func testARetainedOrFailedProviderNeverFires() {
        let retained = service("claude", [week(97)], state: .notRunning)
        XCTAssertTrue(retained.isRetained, "last-known numbers, as retention keeps them")
        let failed = service("codex", [session(99, id: "codex_primary")], state: .error)
        XCTAssertNil(PetAlertSelector.alert(in: [retained, failed], enabledIDs: all))
    }

    func testPromotionalAndPrepaidPoolsNeverFire() {
        let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promotional", percent: 99, kind: .weekly)
        XCTAssertTrue(promo.isPromotional)
        XCTAssertTrue(Fixture.cloudCredits.isCreditPool)
        let services = [service("claude", [promo, Fixture.cloudCredits, session(20)])]
        XCTAssertNil(PetAlertSelector.alert(in: services, enabledIDs: all))
    }

    func testAProviderThatIsSwitchedOffNeverFires() {
        let services = [service("claude", [week(50)]), service("codex", [session(99, id: "codex_primary")])]
        XCTAssertNil(PetAlertSelector.alert(in: services, enabledIDs: ["claude"]))
        XCTAssertEqual(
            PetAlertSelector.alert(in: services, enabledIDs: nil)?.serviceID, "codex",
            "before the first poll nothing is filtered"
        )
    }

    // MARK: - Model-scoped windows (ruling R2, as `UsageNotifier` and `headlinePercent`)

    func testAModelScopedWindowDoesNotAlarmBesideACoreWindow() {
        let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 91, kind: .modelSpecific)
        XCTAssertNil(PetAlertSelector.alert(in: [service("claude", [week(30), opus])], enabledIDs: all))
    }

    /// Live on this Mac when ruled: Argon full for days, the Gemini windows nearly empty, and a
    /// real Claude session at 95 % hidden behind it.
    func testAFullModelWindowNeitherAlarmsNorMasksARealWindowElsewhere() {
        let argon = Fixture.bucket(
            id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 100, kind: .modelSpecific
        )
        let antigravity = service("antigravity", [week(3, id: "antigravity_weekly", label: "Gemini weekly"), argon])
        XCTAssertNil(PetAlertSelector.alert(in: [antigravity], enabledIDs: all))
        XCTAssertEqual(
            PetAlertSelector.alert(in: [antigravity, service("claude", [session(95)])], enabledIDs: all)?.serviceID,
            "claude"
        )
    }

    func testACoreWindowStillAlarmsBesideAModelWindowThatIsFuller() {
        let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 99, kind: .modelSpecific)
        XCTAssertEqual(
            PetAlertSelector.alert(in: [service("claude", [week(92), opus])], enabledIDs: all)?.bucket.id,
            "seven_day"
        )
    }

    /// Scoping is all this provider has, so those windows are its limits.
    func testAProviderWithOnlyModelWindowsStillAlarms() {
        let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 91, kind: .modelSpecific)
        XCTAssertEqual(PetAlertSelector.alert(in: [service("claude", [opus])], enabledIDs: all)?.bucket.id, "seven_day_opus")
    }

    /// A bonus pool is not a core window: beside one, the model windows are still all there is.
    func testAPoolBesideModelWindowsDoesNotTakeTheirPlace() {
        let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 91, kind: .modelSpecific)
        let pool = Fixture.bucket(
            id: "cloud_credits", label: "Cloud session credits", percent: 95, kind: .other,
            credit: CreditPool(usedDollars: 95, limitDollars: 100)
        )
        XCTAssertEqual(PetAlertSelector.alert(in: [service("claude", [pool, opus])], enabledIDs: all)?.bucket.id, "seven_day_opus")
    }

    /// The self-set weekly budget a pay-as-you-go user chose is a limit they want to hear about.
    func testTheSelfSetBudgetWindowStaysEligible() {
        let budget = Fixture.bucket(
            id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget", percent: 93, kind: .weekly
        )
        XCTAssertEqual(
            PetAlertSelector.alert(in: [service("claude", [budget])], enabledIDs: all)?.bucket.id,
            AppState.payAsYouGoBudgetBucketID
        )
    }

    func testAWindowPastItsLimitReadsAsFull() {
        let budget = Fixture.bucket(
            id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget", percent: 137, kind: .weekly
        )
        XCTAssertEqual(PetAlertSelector.alert(in: [service("claude", [budget])], enabledIDs: all)?.usedPercent, 100)
    }
}
