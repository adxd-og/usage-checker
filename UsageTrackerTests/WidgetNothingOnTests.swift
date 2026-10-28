import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, Nothing on: a widget
/// whose file says no provider is on says so and points to Omelette's Settings › Providers,
/// tells that apart from "every enabled provider signed out", and never shows the sample
/// numbers in that state.
final class WidgetNothingOnTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_793_100_000)

    private func file(_ ids: [String], enabledProviders: Int?) -> WidgetSnapshot {
        WidgetSnapshot(
            services: ids.map { id in
                WidgetService(
                    id: id, name: id.capitalized, icon: "sparkles", plan: nil,
                    buckets: [WidgetBucket(id: "\(id)_session", label: "Session", percent: 40, kind: "session")]
                )
            },
            updatedAt: at,
            enabledProviders: enabledProviders
        )
    }

    func testWithEveryProviderOffAProviderWidgetSaysSo() {
        XCTAssertEqual(
            WidgetEntryRules.providerContent(file([], enabledProviders: 0), providerID: "claude"),
            .message(NothingOnCopy.widget)
        )
    }

    func testWithEveryProviderOffTheAllProvidersWidgetSaysSo() {
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(file([], enabledProviders: 0)), .message(NothingOnCopy.widget))
    }

    func testEveryEnabledProviderSignedOutStillReadsAsBefore() {
        let signedOut = file([], enabledProviders: 2)
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(signedOut), .message(WidgetEntryRules.nothingReportingMessage))
        XCTAssertEqual(
            WidgetEntryRules.providerContent(signedOut, providerID: "claude"), .message(WidgetEntryRules.noDataMessage)
        )
    }

    func testAFileThatDoesNotSayReadsAsBefore() {
        let old = file([], enabledProviders: nil)
        XCTAssertFalse(old.isNothingOn)
        XCTAssertEqual(WidgetEntryRules.allProvidersContent(old), .message(WidgetEntryRules.nothingReportingMessage))
    }

    func testNothingOnNeverBringsTheSampleNumbersBack() {
        let off = file([], enabledProviders: 0)
        XCTAssertTrue(off.isNothingOn)
        XCTAssertEqual(WidgetEntryRules.snapshot(read: off, isPreview: false), off)
        XCTAssertEqual(
            WidgetEntryRules.snapshot(read: off, isPreview: true), off,
            "the gallery's sample is only for a Mac with no file"
        )
    }

    func testTheWidgetsLineSaysWhereToTurnOneOn() {
        XCTAssertEqual(NothingOnCopy.widget, "All providers are off. Turn one on in Omelette's Settings › Providers.")
    }
}
