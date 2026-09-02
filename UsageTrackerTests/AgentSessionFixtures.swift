import Foundation
@testable import Omelette

extension Fixture {
    /// A hook-tracked Claude session by default. `isApproximate: true` is what the
    /// passive log scan produces, and the UI marks those differently.
    ///
    /// `AgentSession.id` is not a parameter: the model computes it as
    /// `AgentSession.makeID(source:sessionID:)`, so `sessionID` is what makes two
    /// fixture sessions distinct.
    static func agentSession(
        sessionID: String = "s1",
        source: AgentSource = .claude,
        projectName: String = "Usage tracker",
        cwd: String? = "/Users/me/Desktop/Usage tracker",
        state: AgentState = .working,
        activity: String? = nil,
        stateSince: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastEventAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        startedAt: Date = Date(timeIntervalSince1970: 1_699_000_000),
        host: AgentHostInfo = AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
        isApproximate: Bool = false,
        turns: Int = 1,
        needsYouCount: Int = 0
    ) -> AgentSession {
        AgentSession(
            sessionID: sessionID,
            source: source,
            projectName: projectName,
            cwd: cwd,
            state: state,
            activity: activity,
            stateSince: stateSince,
            lastEventAt: lastEventAt,
            startedAt: startedAt,
            host: host,
            isApproximate: isApproximate,
            turns: turns,
            needsYouCount: needsYouCount
        )
    }
}
