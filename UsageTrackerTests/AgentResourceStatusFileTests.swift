import Combine
import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Wire format: `status.json`, `brioche status --json` (the
/// file verbatim) and MCP `get_agents` gain two optional fields per live session, `cpuPercent`
/// (per core) and `memoryBytes`, absent when not measured; no existing field changes and the
/// version stays 2. § Which processes: on a tty several live sessions share, only the most
/// recently active one carries the figures. § Sampling: the 5 s readings feed the views only;
/// `status.json` takes new figures at most every 30 s.
final class AgentResourceStatusFileTests: XCTestCase {
    private typealias F = AgentProcessFixture
    private typealias Figures = AgentResourceRules.Figures
    private let now = AgentProcessFixture.t0

    private func session(_ id: String, project: String, tty: String?) -> AgentSession {
        Fixture.agentSession(
            sessionID: id, projectName: project, state: .working,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: tty)
        )
    }

    /// A busy tab with two readings, a tab with its first reading only, an IDE panel.
    private var sessions: [AgentSession] {
        [
            session("a", project: "Usage tracker", tty: F.tab),
            session("b", project: "Orion", tty: F.otherTab),
            session("c", project: "Panel", tty: nil),
        ]
    }

    private let byTTY: [String: AgentResourceRules.Figures] = [
        AgentProcessFixture.tab: AgentResourceRules.Figures(cpuPercent: 212.34, memoryBytes: 2099 * AgentProcessFixture.mb),
        AgentProcessFixture.otherTab: AgentResourceRules.Figures(cpuPercent: nil, memoryBytes: 634 * AgentProcessFixture.mb),
    ]

    /// What the file takes from the monitor: each session's figures by id.
    private func file(_ listed: [AgentSession]? = nil) -> StatusSnapshot {
        let live = listed ?? sessions
        return StatusFileWriter.build(
            services: [], costs: [:],
            agents: StatusFileWriter.AgentSummary(sessions: live),
            resources: AgentResourceRules.bySession(live, byTTY: byTTY), now: now
        )
    }

    func testAMeasuredSessionCarriesItsCPUAndMemory() {
        let listed = file().agents.sessions
        XCTAssertEqual(listed.map(\.id), ["claude:a", "claude:b", "claude:c"])
        XCTAssertEqual(listed[0].cpuPercent, 212.3)
        XCTAssertEqual(listed[0].memoryBytes, 2_200_961_024)
        XCTAssertNil(listed[1].cpuPercent, "its first reading: memory only")
        XCTAssertEqual(listed[1].memoryBytes, 664_797_184)
        XCTAssertNil(listed[2].cpuPercent, "an IDE panel has no tty")
        XCTAssertNil(listed[2].memoryBytes)
    }

    func testTheCPUIsPerCoreToOneDecimal() {
        XCTAssertEqual(AgentResourceRules.wirePercent(232.04), 232.0)
        XCTAssertEqual(AgentResourceRules.wirePercent(212.345), 212.3)
        XCTAssertEqual(AgentResourceRules.wirePercent(1520.06), 1520.1)
        XCTAssertEqual(AgentResourceRules.wirePercent(0.04), 0)
        XCTAssertEqual(AgentResourceRules.wirePercent(-3), 0)
        XCTAssertEqual(AgentResourceRules.wirePercent(.nan), 0)
    }

    func testUnmeasuredFieldsAreAbsentKeysNotNull() throws {
        let text = String(decoding: try StatusFile.encoder.encode(file()), as: UTF8.self)
        XCTAssertTrue(text.contains("\"cpuPercent\" : 212.3"), text)
        XCTAssertTrue(text.contains("\"memoryBytes\" : 2200961024"), text)
        XCTAssertTrue(text.contains("\"memoryBytes\" : 664797184"), text)
        XCTAssertEqual(text.components(separatedBy: "\"cpuPercent\"").count - 1, 1, "only the measured session's CPU")
        XCTAssertEqual(text.components(separatedBy: "\"memoryBytes\"").count - 1, 2)
        XCTAssertFalse(text.contains("null"), text)
    }

    func testTheFileStaysVersionTwoAndAnOlderFileStillOpens() throws {
        XCTAssertEqual(StatusSnapshot.currentVersion, 2)
        XCTAssertEqual(file().version, 2)
        let older = #"{"version":2,"updatedAt":"2026-11-19T12:00:00Z","services":[],"agents":{"needsYou":0,"working":1,"sessions":[{"id":"claude:a","project":"Usage tracker","state":"working"}]}}"#
        let decoded = try StatusFile.decoder.decode(StatusSnapshot.self, from: Data(older.utf8))
        XCTAssertNil(decoded.agents.sessions.first?.cpuPercent)
        XCTAssertNil(decoded.agents.sessions.first?.memoryBytes)
        let roundTrip = try StatusFile.decoder.decode(StatusSnapshot.self, from: StatusFile.encoder.encode(file()))
        XCTAssertEqual(roundTrip, file())
    }

    func testGetAgentsCarriesBothFieldsWhereMeasured() throws {
        let line = try XCTUnwrap(MCPServer.handle(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_agents","arguments":{}}}"#,
            snapshot: file(), now: now
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let agents = try XCTUnwrap(structured["agents"] as? [String: Any])
        let listed = try XCTUnwrap(agents["sessions"] as? [[String: Any]])
        XCTAssertEqual(listed[0]["cpuPercent"] as? Double, 212.3)
        XCTAssertEqual(listed[0]["memoryBytes"] as? Int, 2_200_961_024)
        XCTAssertNil(listed[1]["cpuPercent"])
        XCTAssertEqual(listed[1]["memoryBytes"] as? Int, 664_797_184)
        XCTAssertNil(listed[2]["cpuPercent"])
        XCTAssertNil(listed[2]["memoryBytes"])
    }

    /// § Which processes: a `claude` that ended without `SessionEnd` stays live while its tab is
    /// open; only the most recently active session on the tty (`lastEventAt`) carries its
    /// figures on the wire, so one tree is never counted twice.
    func testOnlyTheMostRecentlyActiveSessionOnATTYCarriesItsFigures() {
        let stale = Fixture.agentSession(
            sessionID: "old", projectName: "Usage tracker", state: .idle,
            lastEventAt: now.addingTimeInterval(-3600), host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
        )
        let current = Fixture.agentSession(
            sessionID: "new", projectName: "Usage tracker", state: .working,
            lastEventAt: now, host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
        )
        let listed = file([stale, current]).agents.sessions
        XCTAssertEqual(listed.map(\.id), ["claude:old", "claude:new"])
        XCTAssertEqual(listed.map(\.memoryBytes), [nil, 2_200_961_024])
        XCTAssertEqual(listed.map(\.cpuPercent), [nil, 212.3])
    }

    /// § Sampling (review question 1): the 5 s readings feed the views only; new figures reach
    /// `status.json` at most every 30 s.
    func testNewFiguresReachTheFileAtMostEveryThirtySeconds() {
        let last = ["claude:a": Figures(cpuPercent: 10, memoryBytes: 634 * F.mb)]
        let next = ["claude:a": Figures(cpuPercent: 212.34, memoryBytes: 634 * F.mb)]
        XCTAssertFalse(AgentResourceRules.publishesToFile(next, over: last, lastAt: now, now: now.addingTimeInterval(29)))
        XCTAssertTrue(AgentResourceRules.publishesToFile(next, over: last, lastAt: now, now: now.addingTimeInterval(30)))
        XCTAssertTrue(AgentResourceRules.publishesToFile(next, over: last, lastAt: nil, now: now), "nothing taken yet")
        XCTAssertTrue(
            AgentResourceRules.publishesToFile(next, over: last, lastAt: now, now: now.addingTimeInterval(-1)),
            "a clock that went back"
        )
    }

    /// A session that gains its first figures, or loses them — it ended, a newer session took its
    /// tty, or a newer tab reused it — reaches the file at once, so the file never shows one
    /// tree on two sessions for half a minute.
    func testASessionGainingOrLosingItsFiguresReachesTheFileAtOnce() {
        let one = ["claude:a": Figures(cpuPercent: 10, memoryBytes: 634 * F.mb)]
        let two = one.merging(["claude:b": Figures(cpuPercent: nil, memoryBytes: 415 * F.mb)]) { first, _ in first }
        let soon = now.addingTimeInterval(1)
        XCTAssertTrue(AgentResourceRules.publishesToFile(two, over: one, lastAt: now, now: soon), "a session's first reading")
        XCTAssertTrue(AgentResourceRules.publishesToFile(one, over: two, lastAt: now, now: soon), "a session that lost its figures")
        XCTAssertTrue(AgentResourceRules.publishesToFile([:], over: one, lastAt: now, now: soon), "the last tty gone")
    }

    // MARK: The write a resource change issues (session amendment after Task 4)

    /// A plain `@Published` list standing in for `AgentSessionStore.$sessions`: it sends the new
    /// list inside its `willSet`, while its own property still holds the old one, as the store's.
    private final class SessionList {
        @Published var sessions: [AgentSession] = []
    }

    /// Session amendment (2026-11-19): a session that ends changes the monitor's `bySession`
    /// inside the session store's `willSet`, where the store still holds the list from before
    /// the change. The write issued for that resource change takes its agents from the list the
    /// monitor was handed, so the session that ended does not come back in `status.json`.
    @MainActor
    func testASessionThatEndedDoesNotComeBackInTheWriteItsResourceChangeIssues() async throws {
        let store = SessionList()
        let monitor = AgentResourceMonitor(
            sampler: FakeMachine().sampler(), now: { AgentProcessFixture.t0 },
            sleep: { _ in _ = try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        )
        let ended = Fixture.agentSession(
            sessionID: "a", projectName: "Usage tracker", lastEventAt: now,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
        )
        let kept = Fixture.agentSession(
            sessionID: "b", projectName: "Orion", lastEventAt: now,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.otherTab)
        )
        store.sessions = [ended, kept]
        monitor.follow(store.$sessions)
        let sampled = expectation(description: "both tabs read")
        let first = monitor.$bySession.first { $0.count == 2 }.sink { _ in sampled.fulfill() }
        await fulfillment(of: [sampled], timeout: 5)
        first.cancel()

        var writes: [(figures: [String: Figures], agents: StatusFileWriter.AgentSummary)] = []
        var heldByTheStore: [[String]] = []
        let observer = AppState.resourceWrites(of: monitor).sink { write in
            writes.append(write)
            heldByTheStore.append(store.sessions.map(\.id))
        }
        defer { observer.cancel() }
        store.sessions = [kept]

        XCTAssertEqual(writes.count, 1, "losing a session's figures issues one write")
        let write = try XCTUnwrap(writes.last)
        XCTAssertEqual(heldByTheStore.last, [ended.id, kept.id], "the store still held the list from before the change")
        let listed = StatusFileWriter.build(
            services: [], costs: [:], agents: write.agents, resources: write.figures, now: now
        ).agents.sessions
        XCTAssertEqual(listed.map(\.id), [kept.id])
        XCTAssertEqual(listed.first?.memoryBytes, 415 * F.mb)
        monitor.update(sessions: [])
    }
}
