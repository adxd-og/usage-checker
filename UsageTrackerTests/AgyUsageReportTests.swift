import XCTest
@testable import Omelette

/// `AgyUsageReport.parse`: agy's `/usage` stdout as quota groups (spec
/// 2026-10-16-antigravity-argon § "Package 2", Facts: `command.data.groups[]`, each with
/// `name` and `buckets[]` of `id`, `name`, `window`, `remaining_fraction`, `reset_time`).
final class AgyUsageReportTests: XCTestCase {
    private typealias A = AgyUsageFixture
    private typealias F = AntigravityFixture

    /// The live answer, group by group, as agy listed them.
    private var liveReport: AgyUsageReport {
        AgyUsageReport(groups: [
            AgyUsageReport.Group(name: "Gemini Models", buckets: [
                AgyUsageReport.Bucket(id: "gemini-weekly", name: "Weekly Limit Remaining", window: "weekly",
                                      remainingFraction: 0.9916762113571167, resetTime: F.geminiWeeklyReset, disabled: false),
                AgyUsageReport.Bucket(id: "gemini-5h", name: "Five Hour Limit Remaining", window: "5h",
                                      remainingFraction: 0.9899333119392395, resetTime: F.gemini5hReset, disabled: false),
            ]),
            AgyUsageReport.Group(name: "Claude and GPT models", buckets: [
                AgyUsageReport.Bucket(id: "3p-weekly", name: "Weekly Limit Remaining", window: "weekly",
                                      remainingFraction: 1, resetTime: A.thirdPartyWeeklyReset, disabled: false),
                AgyUsageReport.Bucket(id: "3p-5h", name: "Five Hour Limit Remaining", window: "5h",
                                      remainingFraction: 1, resetTime: A.thirdParty5hReset, disabled: false),
            ]),
            AgyUsageReport.Group(name: "Gemini 4 Argon", buckets: [
                AgyUsageReport.Bucket(id: "gemini-argon-wtu-weekly", name: "Gemini 4 Argon Weekly Limit", window: "weekly",
                                      remainingFraction: 0.5255658626556396, resetTime: F.argonWeeklyReset, disabled: false),
            ]),
        ])
    }

    func testTheLiveOutputIsThreeGroupsWithTheirBuckets() throws {
        XCTAssertEqual(try AgyUsageReport.parse(A.proOutput), liveReport)
    }

    func testAStatusOtherThanSuccessIsNoReading() {
        XCTAssertThrowsError(try AgyUsageReport.parse(A.signedOutOutput)) { error in
            XCTAssertEqual(error as? AgyUsageError, .status("ERROR"))
        }
        XCTAssertThrowsError(try AgyUsageReport.parse(Data(#"{"num_turns":0}"#.utf8))) { error in
            XCTAssertEqual(error as? AgyUsageError, .status(""), "no status at all is not SUCCESS either")
        }
    }

    func testANoticeBeforeTheObjectIsSkipped() throws {
        XCTAssertEqual(try AgyUsageReport.parse(A.proOutputAfterANotice), liveReport)
    }

    func testOutputWithNoJSONObjectIsUnreadable() {
        for text in ["", "zsh: command not found: agy", "{ not json }"] {
            XCTAssertThrowsError(try AgyUsageReport.parse(Data(text.utf8))) { error in
                guard case .unreadable? = error as? AgyUsageError else {
                    return XCTFail("\(text): expected unreadable, got \(error)")
                }
            }
        }
    }

    func testAnAnswerWithNoQuotaGroupIsUnreadable() {
        let outputs = [
            A.output(groups: "[]"),
            A.output(groups: #"[{"name":"Gemini Models","buckets":[]}]"#),
            Data(#"{"status":"SUCCESS"}"#.utf8),
        ]
        for output in outputs {
            XCTAssertThrowsError(try AgyUsageReport.parse(output)) { error in
                guard case .unreadable? = error as? AgyUsageError else {
                    return XCTFail("expected unreadable, got \(error)")
                }
            }
        }
    }

    func testABucketWithoutAnIDIsDroppedAndOneWithoutANameTakesItsID() throws {
        let output = A.output(groups: #"""
        [{"name":"  Claude and GPT models  ","buckets":[
          {"id":"  ","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.5},
          {"id":"3p-5h","window":"5h","remaining_fraction":0.25,"reset_time":"2026-10-16T13:02:02Z"}]}]
        """#)
        XCTAssertEqual(try AgyUsageReport.parse(output), AgyUsageReport(groups: [
            AgyUsageReport.Group(name: "Claude and GPT models", buckets: [
                AgyUsageReport.Bucket(id: "3p-5h", name: "3p-5h", window: "5h", remainingFraction: 0.25,
                                      resetTime: A.thirdParty5hReset, disabled: false),
            ]),
        ]))
    }

    func testResetTimesReadWithOrWithoutFractionalSeconds() throws {
        let output = A.output(groups: #"""
        [{"name":"Gemini Models","buckets":[
          {"id":"gemini-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-23T07:46:06.250Z"},
          {"id":"gemini-5h","window":"5h","remaining_fraction":1,"reset_time":"next Friday"}]}]
        """#)
        let resets = try AgyUsageReport.parse(output).groups[0].buckets.map(\.resetTime)
        XCTAssertEqual(resets[0]?.timeIntervalSince1970 ?? 0, 1_792_741_566.25, accuracy: 0.001)
        XCTAssertNil(resets[1], "a reset agy did not write as ISO-8601 is no reset")
    }
}
