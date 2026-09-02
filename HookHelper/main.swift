import Foundation

// omelette-hook — forwards one Claude Code hook payload (stdin) or one Codex notify
// payload (`--codex '<json>'`) to Omelette over its Unix socket.
//
// Contract with the agents that spawn us: exit 0 no matter what, never block past
// 800 ms, never write to stdout (Claude Code parses a hook's stdout), never persist
// or log a payload. Foundation only — no AppKit.

enum HookMain {
    static let helperVersion = 1
    static let wireVersion = 1
    static let maxLineBytes = 64 * 1024
    static let connectTimeout: TimeInterval = 0.3
    static let replyTimeout: TimeInterval = 0.5
    static let totalBudgetMilliseconds = 800
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"

    static func run() -> Never {
        // Watchdog first: whatever blocks below, the agent gets its process back on time.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(totalBudgetMilliseconds)) {
            // _exit, not exit: the main thread may be blocked inside Foundation
            // holding a lock, and atexit handlers would wait on it forever.
            _exit(0)
        }
        let receivedAt = Date().timeIntervalSince1970

        guard let input = readPayload(CommandLine.arguments) else { exit(0) }
        let host = HostProcess.describe()
        var envelope: [String: Any] = [
            "v": wireVersion,
            "source": input.source,
            "helper_version": helperVersion,
            "received_at": receivedAt,
            "host": [
                "pid": host.pid.map { Int($0) } ?? NSNull(),
                "bundle_id": host.bundleID ?? NSNull(),
                "tty": host.tty ?? NSNull(),
            ] as [String: Any],
            "payload": input.payload,
        ]

        guard var line = encodeLine(envelope) else { exit(0) }
        if line.count > maxLineBytes {
            envelope["payload"] = shrinkingToolInput(input.payload)
            guard let smaller = encodeLine(envelope), smaller.count <= maxLineBytes else { exit(0) }
            line = smaller
        }

        // Only PermissionRequest waits for an answer (phase 4 will carry a decision);
        // everything else is fire-and-forget.
        let wantsReply = input.source == "claude"
            && (input.payload["hook_event_name"] as? String) == "PermissionRequest"
        SocketClient.send(
            line,
            to: socketPath(),
            connectTimeout: connectTimeout,
            replyTimeout: wantsReply ? replyTimeout : 0
        )
        exit(0)
    }

    /// `--codex '<json>'` (Codex `notify`) or the Claude hook JSON on stdin. nil unless
    /// the payload is a JSON object — nothing else is worth a connection.
    static func readPayload(_ arguments: [String]) -> (source: String, payload: [String: Any])? {
        if arguments.count >= 2, arguments[1] == "--codex" {
            guard arguments.count >= 3, let object = parseObject(Data(arguments[2].utf8)) else { return nil }
            return ("codex", object)
        }
        guard let object = parseObject(FileHandle.standardInput.readDataToEndOfFile()) else { return nil }
        return ("claude", object)
    }

    static func parseObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any as? [String: Any]
    }

    /// Compact JSON + "\n". JSONSerialization escapes newlines inside strings, so one
    /// message is always exactly one line.
    static func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    /// A Write's `tool_input` carries the whole file. Keep only the keys the app
    /// summarises (capped) so the event still counts as `working` with an activity.
    static func shrinkingToolInput(_ payload: [String: Any]) -> [String: Any] {
        var shrunk = payload
        var kept: [String: Any] = ["_omelette_truncated": true]
        if let input = payload["tool_input"] as? [String: Any] {
            for key in ["command", "file_path", "notebook_path", "pattern"] {
                if let value = input[key] as? String { kept[key] = String(value.prefix(1024)) }
            }
        }
        shrunk["tool_input"] = kept
        return shrunk
    }

    static func socketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let production = home.appendingPathComponent("Library/Application Support/UsageTracker/agent.sock").path
        guard let override = ProcessInfo.processInfo.environment[socketEnvironmentKey], !override.isEmpty else {
            return production
        }
        // The override exists for the test suite. Anything that can set an
        // environment variable on the agent's process (direnv, a devcontainer, a
        // dependency's install script) must not be able to redirect hook payloads —
        // which include tool inputs — to a socket of its choosing, so only paths in
        // the per-user temp dir or Omelette's own App Support dir are honoured.
        let candidate = URL(fileURLWithPath: override).standardizedFileURL.path
        let allowedRoots = [
            NSTemporaryDirectory(),
            "/private" + NSTemporaryDirectory(),
            home.appendingPathComponent("Library/Application Support/UsageTracker").path + "/",
        ]
        return allowedRoots.contains(where: { candidate.hasPrefix($0) }) ? override : production
    }
}

HookMain.run()
