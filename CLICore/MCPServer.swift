import Foundation

/// `omelette mcp` — a Model Context Protocol server on stdio, as a pure function.
///
/// One line of newline-delimited JSON-RPC 2.0 in, one line out (or nothing, for a
/// notification). No state at all: the snapshot is handed in per call, so the runtime
/// re-reads `status.json` for every request and an agent can never be told what the
/// numbers were a minute ago.
///
/// Only what a client actually needs to launch us: `initialize`,
/// `notifications/initialized`, `tools/list`, `tools/call` and `ping`. The 2026-07-28
/// revision replaced the handshake with `server/discover` and a per-request `_meta`
/// version; every client that launches this binary today still opens with
/// `initialize`, so that is what this answers, and a client that speaks only the newer
/// shape gets a version it can decide about rather than a silent failure.
enum MCPServer {
    static let serverName = "omelette"

    /// What we answer with when the client asks for something we do not know.
    static let defaultProtocolVersion = "2025-06-18"

    /// The handshake-based revisions. The spec is explicit: a version we support comes
    /// back unchanged, anything else comes back as one of ours.
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    static let instructions = "Ask get_usage before starting long or expensive work: it says how full each rate-limit window is and when it resets. get_agents says whether another session is waiting for the user."

    /// Neither tool takes an argument. `additionalProperties: false` is what stops a
    /// model from inventing one and then explaining the resulting error to the user.
    /// Computed, not stored: a `[String: Any]` is not Sendable, and a stored static of
    /// it is a mutable global two callers could reach at once.
    static var emptyInputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [String: Any](),
            "additionalProperties": false,
        ]
    }

    static var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "get_usage",
                "title": "AI usage right now",
                "description": "Every provider Omelette tracks: each rate-limit window's percent and when it resets, today's and this week's cost, and whether those dollars are an API-equivalent figure rather than a subscription bill. Call this before starting long or expensive work.",
                "inputSchema": emptyInputSchema,
            ],
            [
                "name": "get_agents",
                "title": "Agent sessions right now",
                "description": "The Claude Code and Codex sessions Omelette can see: how many need a decision from the user, how many are working, and what each one is doing.",
                "inputSchema": emptyInputSchema,
            ],
        ]
    }

    /// nil means "write nothing" — a notification, or a blank line.
    static func handle(_ requestLine: String, snapshot: StatusSnapshot?, now: Date) -> String? {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let any = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return error(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let object = any as? [String: Any] else {
            return error(id: NSNull(), code: -32600, message: "Invalid Request: expected a JSON object")
        }

        // A request with no id is a notification: it gets no answer whatever it asks
        // for, which is what makes `notifications/initialized` a no-op and not a case.
        guard let id = object["id"] else { return nil }
        guard let method = object["method"] as? String else {
            return error(id: id, code: -32600, message: "Invalid Request: no method")
        }

        switch method {
        case "initialize":
            return result(id: id, initializeResult(object["params"] as? [String: Any]))
        case "ping":
            return result(id: id, [String: Any]())
        case "tools/list":
            // Two tools never paginate, so a cursor is accepted and ignored rather
            // than refused, and no `nextCursor` is offered.
            return result(id: id, ["tools": toolDefinitions])
        case "tools/call":
            return toolCall(id: id, params: object["params"] as? [String: Any], snapshot: snapshot, now: now)
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func initializeResult(_ params: [String: Any]?) -> [String: Any] {
        let asked = params?["protocolVersion"] as? String ?? ""
        let version = supportedProtocolVersions.contains(asked) ? asked : defaultProtocolVersion
        return [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": serverName, "version": CLIText.version],
            "instructions": instructions,
        ]
    }

    // MARK: - Encoding

    /// `id` goes back exactly as it arrived — JSON-RPC ids are numbers *or* strings,
    /// and a client matches the response to its request by comparing them.
    static func result(id: Any, _ value: Any) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": value])
    }

    static func error(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// `.sortedKeys` so a response is a string a test can compare, not a dictionary a
    /// test has to walk. The fallback is a well-formed internal error rather than an
    /// empty line: a client waiting on one response must always get one.
    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return text
    }

    // MARK: - Tools

    static func toolCall(
        id: Any, params: [String: Any]?, snapshot: StatusSnapshot?, now: Date
    ) -> String {
        guard let name = params?["name"] as? String else {
            return error(id: id, code: -32602, message: "tools/call needs a tool name")
        }
        switch name {
        case "get_usage":
            guard let snapshot else { return result(id: id, notRunningResult) }
            return result(id: id, toolResult(
                text: MCPSummary.usage(snapshot: snapshot, now: now),
                data: usageData(snapshot)
            ))
        case "get_agents":
            guard let snapshot else { return result(id: id, notRunningResult) }
            return result(id: id, toolResult(
                text: MCPSummary.agents(snapshot: snapshot, now: now),
                data: agentsData(snapshot)
            ))
        default:
            return error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    /// A result, not a protocol error: "Omelette is closed" is an answer, and a
    /// -32603 would have the client decide the server is broken and stop asking.
    static var notRunningResult: [String: Any] {
        [
            "content": [["type": "text", "text": CLIText.notRunning + "."]],
            "isError": true,
        ]
    }

    /// Both blocks the spec asks of a tool with structured content: the paragraph a
    /// model acts on, and the same data serialised for a client that reads only text.
    /// No `outputSchema` is declared — a schema obliges the server to conform to it
    /// exactly, and `status.json` grows keys between releases.
    static func toolResult(text: String, data: [String: Any]) -> [String: Any] {
        let serialised = (try? JSONSerialization.data(
            withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [
            "content": [
                ["type": "text", "text": text],
                ["type": "text", "text": serialised],
            ],
            "structuredContent": data,
            "isError": false,
        ]
    }

    /// The snapshot as JSON, minus the agents. Re-encoded through the same `Codable`
    /// the file uses rather than hand-mapped, so a key added to `StatusSnapshot`
    /// reaches the tool without a second edit.
    static func usageData(_ snapshot: StatusSnapshot) -> [String: Any] {
        var object = jsonObject(snapshot)
        object.removeValue(forKey: "agents")
        return object
    }

    static func agentsData(_ snapshot: StatusSnapshot) -> [String: Any] {
        let object = jsonObject(snapshot)
        return [
            "updatedAt": object["updatedAt"] ?? NSNull(),
            "agents": object["agents"] ?? [String: Any](),
        ]
    }

    private static func jsonObject(_ snapshot: StatusSnapshot) -> [String: Any] {
        guard let data = try? StatusFile.encoder.encode(snapshot),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
