import Foundation

/// Turns one wire line from `omelette-hook` into an `AgentEvent`.
enum AgentEventDecoder {
    /// Spec cap per message. The server enforces it while reading; this is the
    /// second line of defence for callers that hand over a whole buffer.
    static let maxLineBytes = 64 * 1024

    enum Error: Swift.Error, Equatable {
        case notJSON
        case unsupportedVersion(Int)
        case missingField(String)
        case tooLarge
    }

    /// Parses one wire line. Throws `AgentEventDecoder.Error` on malformed input.
    static func decode(_ line: Data) throws -> AgentEvent {
        guard line.count <= maxLineBytes else { throw Error.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let envelope = object as? [String: Any] else { throw Error.notJSON }
        guard let version = envelope["v"] as? Int else { throw Error.missingField("v") }
        guard version == AgentPaths.wireVersion else { throw Error.unsupportedVersion(version) }
        guard let sourceRaw = envelope["source"] as? String,
              let source = AgentSource(rawValue: sourceRaw) else { throw Error.missingField("source") }
        guard let payload = envelope["payload"] as? [String: Any] else { throw Error.missingField("payload") }

        let receivedAt = (envelope["received_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let host = decodeHost(envelope["host"] as? [String: Any])

        switch source {
        case .claude: return try claudeEvent(payload: payload, host: host, receivedAt: receivedAt)
        case .codex: return try codexEvent(payload: payload, host: host, receivedAt: receivedAt)
        }
    }

    private static func decodeHost(_ object: [String: Any]?) -> AgentHostInfo {
        guard let object else { return .none }
        return AgentHostInfo(
            pid: (object["pid"] as? Int).flatMap { Int32(exactly: $0) },
            bundleID: object["bundle_id"] as? String,
            tty: object["tty"] as? String
        )
    }

    private static func claudeEvent(payload: [String: Any], host: AgentHostInfo, receivedAt: Date) throws -> AgentEvent {
        guard let name = payload["hook_event_name"] as? String else { throw Error.missingField("hook_event_name") }
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { throw Error.missingField("session_id") }
        let toolName = payload["tool_name"] as? String
        let toolInput = payload["tool_input"] as? [String: Any]

        let kind: AgentEvent.Kind
        switch name {
        case "SessionStart": kind = .sessionStart
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse": kind = .toolStarted
        case "PostToolUse": kind = .toolFinished
        case "PermissionRequest": kind = .permissionRequested
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt": kind = .notificationPermission
            case "idle_prompt": kind = .notificationIdle
            case let other: kind = .unknown("Notification:\(other ?? "")")
            }
        case "Stop": kind = .stop
        case "SessionEnd": kind = .sessionEnd
        default: kind = .unknown(name)
        }

        let agentID = payload["agent_id"] as? String
        return AgentEvent(
            source: .claude,
            kind: kind,
            sessionID: sessionID,
            cwd: payload["cwd"] as? String,
            toolName: toolName,
            toolSummary: AgentToolSummary.make(toolName: toolName, toolInput: toolInput),
            isSubagent: !(agentID ?? "").isEmpty,
            host: host,
            receivedAt: receivedAt
        )
    }

    private static func codexEvent(payload: [String: Any], host: AgentHostInfo, receivedAt: Date) throws -> AgentEvent {
        guard let type = payload["type"] as? String else { throw Error.missingField("type") }
        guard let threadID = payload["thread-id"] as? String, !threadID.isEmpty else { throw Error.missingField("thread-id") }
        return AgentEvent(
            source: .codex,
            kind: type == "agent-turn-complete" ? .codexTurnComplete : .unknown(type),
            sessionID: threadID,
            cwd: payload["cwd"] as? String,
            toolName: nil,
            toolSummary: nil,
            isSubagent: false,
            host: host,
            receivedAt: receivedAt
        )
    }
}
