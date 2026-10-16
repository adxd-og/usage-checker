import XCTest
import CodexBarCore
@testable import Omelette

/// agy's reading as the app's buckets (spec 2026-10-16-antigravity-argon § "Package 2",
/// Design: the same bucket ids as the local path, window length from `window`, a
/// per-model pool labelled with its group's name). The path is `quotaSummary(from:at:)`,
/// then the existing `buckets(from:)`, then `named(_:by:)` with `poolNames(from:)`.
final class AntigravityAgyBucketsTests: XCTestCase {
    private typealias A = AgyUsageFixture
    private typealias F = AntigravityFixture
    private let week: TimeInterval = 604_800
    private let fiveHours: TimeInterval = 18_000

    /// An agy answer as the provider publishes it.
    private func buckets(_ output: Data) throws -> [UsageBucket] {
        let report = try AgyUsageReport.parse(output)
        return AntigravityProvider.named(
            AntigravityProvider.buckets(from: AntigravityProvider.quotaSummary(from: report, at: A.readAt)),
            by: AntigravityProvider.poolNames(from: report)
        )
    }

    /// The live answer's numbers as the running app's probe hands them over: its window
    /// ids, titles, minutes and order (5-hour before weekly, Argon's group after the
    /// Gemini pool and before Claude/GPT).
    private var liveNumbersAsTheProbeHandsThem: CodexBarCore.UsageSnapshot {
        F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "gemini-5h", title: "Gemini 5-hour", percent: 100 - 0.9899333119392395 * 100,
                            minutes: 300, resetsAt: F.gemini5hReset),
            F.summaryWindow(bucketID: "gemini-weekly", title: "Gemini weekly", percent: 100 - 0.9916762113571167 * 100,
                            minutes: 10080, resetsAt: F.geminiWeeklyReset),
            F.summaryWindow(bucketID: "gemini-argon-wtu-weekly", title: "Gemini weekly",
                            percent: 100 - 0.5255658626556396 * 100, minutes: 10080, resetsAt: F.argonWeeklyReset),
            F.summaryWindow(bucketID: "3p-5h", title: "Claude/GPT 5-hour", percent: 0,
                            minutes: 300, resetsAt: A.thirdParty5hReset),
            F.summaryWindow(bucketID: "3p-weekly", title: "Claude/GPT weekly", percent: 0,
                            minutes: 10080, resetsAt: A.thirdPartyWeeklyReset),
        ])
    }

    /// History keeps one line per window whichever path read it: ids, kinds, lengths,
    /// labels and order equal the local path's for the same numbers.
    func testAgysReadingPublishesWhatTheLocalPathPublishesForTheSameNumbers() throws {
        let report = try AgyUsageReport.parse(A.proOutput)
        XCTAssertEqual(
            AntigravityProvider.buckets(from: AntigravityProvider.quotaSummary(from: report, at: A.readAt)),
            AntigravityProvider.buckets(from: liveNumbersAsTheProbeHandsThem)
        )
    }

    /// The probe reads a bucket's cadence from its id and its name under a set of aliases
    /// (CodexBarCore's `quotaBucketKind`), so agy's buckets are read by the same rule and a
    /// bucket gets the same kind and length on both paths, whatever it is called: a weekly
    /// named only by its name (id `3p`), a 5-hour whose id ends in `-five-hour`, an id
    /// spelled with `_`, and a `window` field that disagrees with the id (the id wins, as
    /// on the probe's path, which never sees that field).
    func testAliasCadencesMapAsTheProbeMapsThem() throws {
        let output = A.output(groups: #"""
        [{"name":"Claude and GPT models","buckets":[
           {"id":"3p","name":"weekly","remaining_fraction":0.75,"reset_time":"2026-10-23T08:02:02Z"},
           {"id":"3p_5h","name":"Five Hour Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-16T13:02:02Z"}]},
         {"name":"Gemini 4 Argon","buckets":[
           {"id":"gemini-argon-wtu-five-hour","name":"Gemini 4 Argon Five Hour Limit","remaining_fraction":0.5,"reset_time":"2026-10-16T13:02:02Z"}]}]
        """#)
        let probe = F.usage(primary: nil, secondary: nil, windows: [
            F.summaryWindow(bucketID: "gemini-argon-wtu-five-hour", title: "Gemini 5-hour", percent: 50,
                            minutes: 300, resetsAt: A.thirdParty5hReset),
            F.summaryWindow(bucketID: "3p_5h", title: "Claude/GPT 5-hour", percent: 0,
                            minutes: 300, resetsAt: A.thirdParty5hReset),
            F.summaryWindow(bucketID: "3p", title: "Claude/GPT weekly", percent: 25,
                            minutes: 10080, resetsAt: A.thirdPartyWeeklyReset),
        ])
        let fromAgy = AntigravityProvider.buckets(
            from: AntigravityProvider.quotaSummary(from: try AgyUsageReport.parse(output), at: A.readAt)
        )
        XCTAssertEqual(fromAgy, AntigravityProvider.buckets(from: probe))
        XCTAssertEqual(fromAgy.map(\.kind), [.modelSpecific, .session, .weekly])
        XCTAssertEqual(fromAgy.map(\.windowLength), [fiveHours, fiveHours, week])
    }

    func testAgyNamesArgonAfterItsGroup() throws {
        XCTAssertEqual(try buckets(A.proOutput), A.proBuckets)
        XCTAssertEqual(
            AntigravityProvider.poolNames(from: try AgyUsageReport.parse(A.proOutput)),
            ["antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly": "Gemini 4 Argon"]
        )
    }

    func testAnUltraShapedReadingIsTheFourPoolWindowsAndNoName() throws {
        XCTAssertEqual(try buckets(A.ultraOutput), A.proBuckets.filter { $0.kind != .modelSpecific })
        XCTAssertEqual(AntigravityProvider.poolNames(from: try AgyUsageReport.parse(A.ultraOutput)), [:])
    }

    /// The id and the name give the cadence as the probe reads them; agy's `window` gives
    /// the length of a bucket whose id and name name none.
    func testTheIDGivesTheCadenceAndTheWindowFieldIsTheFallback() throws {
        let output = A.output(groups: #"""
        [{"name":"Claude and GPT models","buckets":[
           {"id":"3p-weekly","name":"Weekly Limit Remaining","remaining_fraction":0.75,"reset_time":"2026-10-23T08:02:02Z"}]},
         {"name":"Argon Turbo","buckets":[
           {"id":"argon-turbo","name":"Argon Turbo Limit","window":"5h","remaining_fraction":0.5,"reset_time":"2026-10-16T13:02:02Z"}]}]
        """#)
        XCTAssertEqual(try buckets(output), [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", percent: 25,
                           resetsAt: A.thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-argon-turbo", label: "Argon Turbo", percent: 50,
                           resetsAt: A.thirdParty5hReset, kind: .modelSpecific, windowLength: fiveHours),
        ])
    }

    /// Two groups under one name would make two rows read alike: neither takes the name,
    /// and the stem rule tells them apart.
    func testTwoGroupsUnderOneNameKeepTheirStemNames() throws {
        let output = A.output(groups: #"""
        [{"name":"Argon","buckets":[{"id":"argon-wtu-weekly","window":"weekly","remaining_fraction":0.5}]},
         {"name":"Argon","buckets":[{"id":"argon-std-weekly","window":"weekly","remaining_fraction":0.25}]}]
        """#)
        XCTAssertEqual(AntigravityProvider.poolNames(from: try AgyUsageReport.parse(output)), [:])
        XCTAssertEqual(try buckets(output).map(\.label), ["Argon Wtu", "Argon Std"])
    }

    func testAGroupWithoutAUsableNameKeepsTheStemName() throws {
        let output = A.output(groups: #"""
        [{"name":"  ","buckets":[{"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":0.5}]},
         {"name":"—","buckets":[{"id":"argon-zinc-weekly","window":"weekly","remaining_fraction":0.5}]}]
        """#)
        XCTAssertEqual(AntigravityProvider.poolNames(from: try AgyUsageReport.parse(output)), [:])
        XCTAssertEqual(try buckets(output).map(\.label), ["Gemini Argon", "Argon Zinc"])
    }

    func testANameNeverRenamesAPoolRow() {
        let pool = Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly",
                                  kind: .weekly, windowLength: week)
        let argon = Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly",
                                   label: "Gemini Argon", kind: .modelSpecific, windowLength: week)
        let names = [pool.id: "Gemini Models", argon.id: "Gemini 4 Argon"]
        XCTAssertEqual(AntigravityProvider.named([pool, argon], by: names).map(\.label), ["Gemini weekly", "Gemini 4 Argon"])
    }

    func testABucketWithNothingReportedOrDisabledIsNoRow() throws {
        let output = A.output(groups: #"""
        [{"name":"Gemini Models","buckets":[
           {"id":"gemini-weekly","window":"weekly","reset_time":"2026-10-23T07:46:06Z"},
           {"id":"gemini-5h","window":"5h","remaining_fraction":0.5,"disabled":true}]},
         {"name":"Gemini 4 Argon","buckets":[
           {"id":"gemini-argon-wtu-weekly","window":"weekly","remaining_fraction":0.5}]}]
        """#)
        XCTAssertEqual(try buckets(output).map(\.id), ["antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly"])
    }
}
