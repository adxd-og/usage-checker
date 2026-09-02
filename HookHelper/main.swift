import Foundation

// omelette-hook — forwards one Claude Code hook payload (stdin) or one Codex notify
// payload (`--codex '<json>'`) to Omelette over its Unix socket, and for a Claude
// `PermissionRequest` waits for Omelette's decision.
//
// Contract with the agents that spawn us: exit 0 no matter what; never block past
// 800 ms unless Omelette is actually listening and this is a PermissionRequest
// (then ≤ 140 s, watchdog at 145 s); write to stdout only the one decision line
// Claude Code understands, and only for a reply that carries our own request id;
// never persist or log a payload. Foundation only — no AppKit, no Security.

enum HookMain {
    static let helperVersion = 2
    static let wireVersion = 2
    static let maxLineBytes = 64 * 1024
    static let connectTimeout: TimeInterval = 0.3
    static let totalBudgetMilliseconds = 800
    /// Spec rule 5: helper ≤ 140 s < hook timeout 150 s; the app gives up at 120 s.
    static let decisionTimeout: TimeInterval = 140
    /// The PermissionRequest watchdog fires this long after the decision deadline.
    static let permissionWatchdogGraceMilliseconds = 5_000
    static let socketEnvironmentKey = "OMELETTE_AGENT_SOCKET"
    static let decisionTimeoutEnvironmentKey = "OMELETTE_DECISION_TIMEOUT"
    static let requestIDBytes = 16

    static func run() -> Never {
        // Watchdog first: whatever blocks below, the agent gets its process back on time.
        let watchdog = Watchdog.arm(milliseconds: totalBudgetMilliseconds)
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

        // Only a Claude PermissionRequest gets an id and waits for a decision. No id
        // (the random source failed) degrades to phase-2 behaviour: sent, not held.
        let isPermissionRequest = input.source == "claude"
            && (input.payload["hook_event_name"] as? String) == "PermissionRequest"
        let requestID = isPermissionRequest ? makeRequestID() : nil
        if let requestID { envelope["request_id"] = requestID }

        guard var line = encodeLine(envelope) else { exit(0) }
        if line.count > maxLineBytes {
            envelope["payload"] = shrinkingToolInput(input.payload)
            guard let smaller = encodeLine(envelope), smaller.count <= maxLineBytes else { exit(0) }
            line = smaller
        }

        let socket = socketPath(environment: ProcessInfo.processInfo.environment)
        guard let fd = SocketClient.send(line, to: socket.path, connectTimeout: connectTimeout) else { exit(0) }
        guard let requestID else {
            close(fd)
            exit(0)
        }

        // Omelette is listening and has our request: swap the 800 ms watchdog for the
        // long one, then wait. Cancelling an unfired DispatchWorkItem is what makes
        // the swap safe; if it fired already we are gone anyway.
        let timeout = decisionTimeout(environment: ProcessInfo.processInfo.environment, overrideAllowed: socket.overridden)
        watchdog.cancel()
        Watchdog.arm(milliseconds: Int(timeout * 1000) + permissionWatchdogGraceMilliseconds)
        let decision = SocketClient.awaitDecision(fd: fd, requestID: requestID, timeout: timeout)
        close(fd)
        if let decision {
            FileHandle.standardOutput.write(Data(decisionOutput(decision).utf8))
        }
        exit(0)
    }

    /// The one line Claude Code reads. `decision` is "allow" or "deny" — nothing else
    /// reaches this function (see `SocketClient.awaitDecision`).
    static func decisionOutput(_ decision: String) -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\#(decision)"}}}"# + "\n"
    }

    /// 128 random bits as 32 lowercase hex characters, from the kernel's pool.
    /// nil if /dev/urandom cannot be read — the caller then sends without an id.
    static func makeRequestID() -> String? {
        guard let urandom = FileHandle(forReadingAtPath: "/dev/urandom"),
              let bytes = try? urandom.read(upToCount: requestIDBytes),
              bytes.count == requestIDBytes else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
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

    /// The socket to talk to, and whether the environment override was honoured.
    static func socketPath(environment: [String: String]) -> (path: String, overridden: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let production = home.appendingPathComponent("Library/Application Support/UsageTracker/agent.sock").path
        #if DEBUG
        // The override exists for the test suite, and only in Debug builds. In a
        // shipped helper anything that can set an environment variable on the
        // agent's process (a repo's settings `env`, direnv, a devcontainer) could
        // otherwise point every PermissionRequest — request id included — at a
        // same-user listener that echoes "allow": the helper cannot authenticate the
        // server, so the only safe release-build socket is the production one. The
        // Debug allowlist (per-user temp dir, Omelette's App Support dir) keeps the
        // E2E tests off the production socket.
        guard let override = environment[socketEnvironmentKey], !override.isEmpty else {
            return (production, false)
        }
        let candidate = URL(fileURLWithPath: override).standardizedFileURL.path
        let allowedRoots = [
            NSTemporaryDirectory(),
            "/private" + NSTemporaryDirectory(),
            home.appendingPathComponent("Library/Application Support/UsageTracker").path + "/",
        ]
        return allowedRoots.contains(where: { candidate.hasPrefix($0) }) ? (override, true) : (production, false)
        #else
        return (production, false)
        #endif
    }

    /// 140 s, or a shorter value from OMELETTE_DECISION_TIMEOUT when — and only when —
    /// the socket override was honoured (tests). Shorter can only mean "no decision",
    /// so this is not a lever anyone can pull to make us print more.
    static func decisionTimeout(environment: [String: String], overrideAllowed: Bool) -> TimeInterval {
        #if DEBUG
        guard overrideAllowed, let raw = environment[decisionTimeoutEnvironmentKey],
              let value = TimeInterval(raw), value > 0 else { return decisionTimeout }
        return min(value, decisionTimeout)
        #else
        return decisionTimeout
        #endif
    }
}

/// `_exit`, not `exit`: the main thread may be blocked inside Foundation holding a
/// lock, and atexit handlers would wait on it forever.
enum Watchdog {
    @discardableResult
    static func arm(milliseconds: Int) -> DispatchWorkItem {
        let item = DispatchWorkItem { _exit(0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item)
        return item
    }
}

HookMain.run()
