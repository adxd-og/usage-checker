import XCTest
@testable import Omelette

/// `status.json` says where a window came from and as of when (spec 2026-11-02 Claude
/// limits from the status line, § Source tag): `source` and `asOf` on a window the status
/// line fed, absent on every other, added keys in version 2, and a file written before
/// them still opens.
final class StatusWindowSourceTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    func testAWindowTheStatusLineFedSaysSoInTheFile() throws {
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(
                    id: "five_hour", label: "Current session", percent: 23.5,
                    resetsAt: Date(timeIntervalSince1970: 1_788_703_200), kind: .session,
                    source: .statusLine, asOf: now.addingTimeInterval(-60)
                ),
                Fixture.bucket(
                    id: "seven_day_opus", label: "Opus only", percent: 12,
                    resetsAt: Date(timeIntervalSince1970: 1_789_065_600), kind: .modelSpecific
                ),
            ],
            at: now
        )

        let snapshot = StatusFileWriter.build(services: [claude], costs: [:], agents: .none, now: now)

        XCTAssertEqual(snapshot.version, 2, "added keys are not a new version")
        XCTAssertEqual(snapshot.services.first?.windows.map(\.source), ["statusLine", nil])
        XCTAssertEqual(snapshot.services.first?.windows.map(\.asOf), [now.addingTimeInterval(-60), nil])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StatusFile.encoder.encode(snapshot)) as? [String: Any]
        )
        let service = try XCTUnwrap((object["services"] as? [[String: Any]])?.first)
        let windows = try XCTUnwrap(service["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["source"] as? String, "statusLine")
        XCTAssertEqual(windows.first?["asOf"] as? String, "2026-09-06T11:19:00Z")
        XCTAssertNil(windows.last?["source"], "absent, never null, where the provider's own fetch filled it")
        XCTAssertNil(windows.last?["asOf"])
    }

    /// A v2 file from before the keys: the CLI and the MCP server must still read it.
    func testAFileWrittenBeforeTheTagStillOpens() throws {
        let file = """
        {"version":2,"updatedAt":"2026-09-06T11:20:00Z","showsRemaining":false,
         "agents":{"needsYou":0,"working":0,"sessions":[]},
         "services":[{"id":"claude","name":"Claude","state":"ok","retained":false,"plan":"Max 20x",
           "windows":[{"id":"five_hour","label":"Current session","percent":23,
                       "resetsAt":"2026-09-06T14:00:00Z","kind":"session"}]}]}
        """

        let snapshot = try StatusFile.decoder.decode(StatusSnapshot.self, from: Data(file.utf8))

        let window = try XCTUnwrap(snapshot.services.first?.windows.first)
        XCTAssertEqual(window.percent, 23)
        XCTAssertNil(window.source)
        XCTAssertNil(window.asOf)
    }
}
