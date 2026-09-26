import XCTest
@testable import Omelette

/// Independent verification of the liquid-glass redesign spec, P8 row: `GeminiProvider`,
/// `GeminiErrorCopy` and their tests, the `geminiProviderEnabled` key, and the `gemini`
/// entry in the provider registry are gone (line 238); § Removals' "Gemini CLI is gone
/// (deprecated)" for Settings › Providers (line 213). The owner's 2026-09-26
/// clarification pins two things this file checks directly: a `gemini` id must fall
/// through to the *same* generic copy any unrecognised id gets (not a bespoke sentence
/// of its own, and not silently reusing Antigravity's), and
/// `ProviderCoordinator.serviceIDs` must equal Settings › Providers' listed ids plus the
/// admin id.
final class GeminiRemovalCopyAndSettingsVerificationTests: XCTestCase {
    // MARK: - DashboardState.costSource

    func testCostSourceForGeminiIsTheSameGenericUnavailableReasonAsAnyUnknownID() {
        let gemini = DashboardState.costSource(for: "gemini")
        let unknown = DashboardState.costSource(for: "some-made-up-provider-id")
        XCTAssertEqual(gemini, unknown, "gemini gets no reason of its own any more")
        XCTAssertEqual(
            gemini,
            .unavailable(reason: "This provider keeps no local cost log, so costs can't be computed. Quota over time is charted instead.")
        )
        XCTAssertFalse(gemini.hasBreakdown)
    }

    /// The dedicated Antigravity branch must survive P8 untouched — the risk with a
    /// `default:` fallback is that a careless refactor folds a still-named case into it.
    func testCostSourceForAntigravityKeepsItsOwnSpecificReason() {
        XCTAssertEqual(
            DashboardState.costSource(for: "antigravity"),
            .unavailable(reason: "Antigravity doesn't keep a local token log, so costs can't be computed. Quota over time is charted instead.")
        )
        XCTAssertNotEqual(
            DashboardState.costSource(for: "antigravity"),
            DashboardState.costSource(for: "gemini"),
            "antigravity's reason must not have collapsed onto the generic one"
        )
    }

    func testCostAggregatorForGeminiIsNilLikeAnyProviderWithNoLog() {
        XCTAssertNil(DashboardState.costAggregator(for: "gemini"))
    }

    // MARK: - HistoryCopy.quotaOnlyNote

    func testQuotaOnlyNoteForGeminiMatchesTheGenericFormulaWithItsOwnPrettifiedLabel() {
        let label = QuotaAnalytics.prettifiedLabel(for: "gemini")
        XCTAssertEqual(label, "Gemini")
        let expected = "\(label) keeps no local token log, so there are no costs or sessions here. Quota over time is charted instead."
        XCTAssertEqual(HistoryCopy.quotaOnlyNote(provider: "gemini"), expected)

        // The removed provider's own sentence must be gone, not merely rephrased.
        XCTAssertFalse(
            HistoryCopy.quotaOnlyNote(provider: "gemini").contains("Omelette doesn't read"),
            "the bespoke Gemini CLI sentence must not still be reachable"
        )

        // Same formula as an arbitrary unrecognised id, modulo the label.
        let otherLabel = QuotaAnalytics.prettifiedLabel(for: "some-made-up-provider-id")
        let otherExpected = "\(otherLabel) keeps no local token log, so there are no costs or sessions here. Quota over time is charted instead."
        XCTAssertEqual(HistoryCopy.quotaOnlyNote(provider: "some-made-up-provider-id"), otherExpected)
    }

    func testQuotaOnlyNoteForAntigravityKeepsItsOwnSentence() {
        XCTAssertEqual(
            HistoryCopy.quotaOnlyNote(provider: "antigravity"),
            "Antigravity keeps no local token log, so there are no costs or sessions here. Quota over time is charted instead."
        )
    }

    // MARK: - Settings: the removed switch

    /// Independent of the executor's own `SettingsStoreTests.testAResetNoLongerWritesTheRemovedGeminiSwitch`:
    /// same claim, a different stored value (`false`, not `true`) to rule out a fix that
    /// special-cased one particular stored value rather than skipping the key outright.
    @MainActor
    func testResetToDefaultsNeverWritesTheRemovedGeminiSwitch() throws {
        let domainName = Bundle.main.bundleIdentifier ?? "com.usagetracker.app"
        let savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
        defer { AppDomainRestore.restore(savedDomain, domainName: domainName) }

        let key = "geminiProviderEnabled"
        UserDefaults.standard.removeObject(forKey: key)
        SettingsStore.shared.resetToDefaults()
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "a reset must not resurrect the removed key")

        UserDefaults.standard.set(false, forKey: key)
        SettingsStore.shared.resetToDefaults()
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? Bool, false,
            "a stored value — even the non-default one — is left exactly where it was"
        )
    }

    // MARK: - The provider registry agrees with itself

    func testProvidersSettingsListedHasNoGeminiID() {
        XCTAssertFalse(ProvidersSettingsCopy.listed.map(\.id).contains("gemini"))
        XCTAssertFalse(ProvidersSettingsCopy.listed.map(\.name).contains("Gemini"))
    }

    func testCoordinatorServiceIDsEqualsListedProvidersPlusTheAdminID() {
        let listedPlusAdmin = Set(ProvidersSettingsCopy.listed.map(\.id)).union([ProvidersSettingsCopy.adminID])
        XCTAssertEqual(ProviderCoordinator.serviceIDs, listedPlusAdmin)
        XCTAssertFalse(ProviderCoordinator.serviceIDs.contains("gemini"))
    }

    /// `rows(services:)` no longer special-cases anything (the deprecated-row filter is
    /// gone by the owner's own instruction); what keeps gemini off the screen is that it
    /// never reaches `services` to begin with. This checks the row builder's ordinary,
    /// undecorated behaviour on a snapshot the app would actually produce post-P8:
    /// nothing but the listed providers plus the admin org.
    func testRowsOnARealisticPostP8SnapshotListsNoGemini() {
        let services = [
            Fixture.snapshot(id: "claude", displayName: "Claude"),
            Fixture.snapshot(id: "antigravity", displayName: "Antigravity"),
            Fixture.snapshot(id: "anthropic-admin", displayName: "Anthropic Enterprise", icon: "building.2"),
        ]
        let rows = ProvidersSettingsCopy.rows(services: services)
        XCTAssertFalse(rows.map(\.id).contains("gemini"))
        XCTAssertEqual(Set(rows.map(\.id)), ["claude", "codex", "antigravity", "grok", "anthropic-admin"])
    }
}
