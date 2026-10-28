import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: the signed-out
/// reason lives on the snapshot only. `status.json` keeps schema 2 and the state word
/// "notSignedIn", and writes the same file whatever the reason (and whatever the message), with
/// or without kept numbers — so `omelette status`, the status line and `get_usage`, which read
/// only the file, say the same too.
final class ClaudeSignedOutStatusFileTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale
    private let now = SessionFixture.now
    private let reasons: [SignedOutReason?] = [nil, .notFound, .expired, .denied, .unreadable]

    private func signedOut(_ reason: SignedOutReason?, keptNumbers: Bool) -> ServiceSnapshot {
        let fresh = ServiceSnapshot.notSignedIn(
            reason: reason, message: "Words for \(String(describing: reason)).", at: now
        )
        guard keptNumbers else { return fresh }
        let earlier = now.addingTimeInterval(-600)
        let previous = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(
                id: "five_hour", label: "Current session", percent: 30,
                resetsAt: now.addingTimeInterval(7200), kind: .session
            )],
            at: earlier
        )
        return AppState.mergingPoll(
            previous: UsageSnapshot(services: [previous], fetchedAt: earlier, isStale: false, lastError: nil),
            next: UsageSnapshot(services: [fresh], fetchedAt: now, isStale: false, lastError: nil)
        ).services[0]
    }

    private func file(_ service: ServiceSnapshot) -> StatusSnapshot {
        StatusFileWriter.build(services: [service], costs: [:], agents: .none, now: now, calendar: calendar, locale: locale)
    }

    func testTheFileIsTheSameWhateverTheReason() throws {
        for kept in [false, true] {
            let files = reasons.map { file(signedOut($0, keptNumbers: kept)) }
            for other in files.dropFirst() { XCTAssertEqual(other, files[0], "kept: \(kept)") }
            let text = try XCTUnwrap(String(data: StatusFile.encoder.encode(files[0]), encoding: .utf8))
            for word in ["expired", "denied", "unreadable", "notFound", "reason", "Words for"] {
                XCTAssertFalse(text.contains(word), "\(word) reached status.json")
            }
            XCTAssertEqual(files[0].version, 2)
            XCTAssertEqual(files[0].services.map(\.state), ["notSignedIn"])
            XCTAssertEqual(files[0].services.map(\.retained), [kept])
        }
    }

    func testOmeletteStatusSaysSignInNeeded() {
        for reason in reasons {
            XCTAssertEqual(
                StatusText.render(snapshot: file(signedOut(reason, keptNumbers: false)), now: now, calendar: calendar, locale: locale),
                "Claude  Sign in needed\n"
            )
        }
    }

    func testGetUsageCarriesTheStateAndNoReason() throws {
        let line = try XCTUnwrap(MCPServer.handle(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_usage","arguments":{}}}"#,
            snapshot: file(signedOut(.expired, keptNumbers: false)), now: now
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        XCTAssertEqual(services.first?["state"] as? String, "notSignedIn")
        XCTAssertNil(services.first?["reason"])
        XCTAssertFalse(line.contains("expired"), line)
    }
}
