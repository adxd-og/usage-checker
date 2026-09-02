import Foundation
@testable import Omelette

/// The exact JSON the agents hand the helper, and the envelope the helper wraps it in.
enum AgentFixture {
    static let hostJSON = #"{"pid":4242,"bundle_id":"com.googlecode.iterm2","tty":"/dev/ttys004"}"#

    /// One Claude Code hook payload. `extra` is appended verbatim inside the object
    /// (leading comma included by this function).
    static func claude(
        _ event: String,
        sessionID: String = "sess-1",
        cwd: String = "/Users/me/Desktop/Usage tracker",
        extra: String = ""
    ) -> String {
        let tail = extra.isEmpty ? "" : "," + extra
        return #"{"session_id":"\#(sessionID)","transcript_path":"/Users/me/.claude/projects/-Users-me-Desktop-Usage-tracker/\#(sessionID).jsonl","cwd":"\#(cwd)","permission_mode":"default","hook_event_name":"\#(event)"\#(tail)}"#
    }

    static let sessionStart = claude("SessionStart", extra: #""source":"startup""#)
    static let userPromptSubmit = claude("UserPromptSubmit", extra: #""prompt":"fix the ring""#)
    static let preToolUseBash = claude("PreToolUse", extra: #""tool_name":"Bash","tool_input":{"command":"xcodegen generate","description":"Regenerate the project"},"tool_use_id":"toolu_01""#)
    static let postToolUseBash = claude("PostToolUse", extra: #""tool_name":"Bash","tool_input":{"command":"xcodegen generate"},"tool_response":{"stdout":"ok","stderr":"","interrupted":false},"tool_use_id":"toolu_01""#)
    static let permissionRequestEdit = claude("PermissionRequest", extra: #""tool_name":"Edit","tool_input":{"file_path":"/Users/me/Desktop/Usage tracker/UsageTracker/UI/WalletView.swift","old_string":"a","new_string":"b"},"tool_use_id":"toolu_02""#)
    static let notificationPermission = claude("Notification", extra: #""message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
    static let notificationIdle = claude("Notification", extra: #""message":"Claude is waiting for your input","notification_type":"idle_prompt""#)
    static let notificationOther = claude("Notification", extra: #""message":"Auth expired","notification_type":"auth_success""#)
    static let stop = claude("Stop", extra: #""stop_hook_active":false"#)
    static let sessionEnd = claude("SessionEnd", extra: #""reason":"exit""#)
    static let subagentPreToolUse = claude("PreToolUse", extra: #""agent_id":"agent-7","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"AgentEvent"}"#)
    static let unknownEvent = claude("SubagentStop", extra: #""agent_id":"agent-7""#)

    /// Codex `notify` argument: kebab-case keys, only `agent-turn-complete` exists today.
    static let codexTurnComplete = #"{"type":"agent-turn-complete","thread-id":"thr-9","turn-id":"turn-2","cwd":"/Users/me/Desktop/Orion Gate","input-messages":["ship it"],"last-assistant-message":"Done."}"#

    /// A 128-bit request id as the helper prints it: 32 lowercase hex characters.
    static let requestID = "0123456789abcdef0123456789abcdef"

    /// The helper's envelope. `v` defaults to the current wire version; pass 1 for a
    /// pre-2.2 helper. `requestID` is only ever present on a `PermissionRequest`.
    static func envelope(
        source: String = "claude",
        payload: String,
        v: Int = 2,
        receivedAt: Double = 1_756_800_000.123,
        host: String = AgentFixture.hostJSON,
        requestID: String? = nil
    ) -> Data {
        let id = requestID.map { #","request_id":"\#($0)""# } ?? ""
        return Data(#"{"v":\#(v),"source":"\#(source)","helper_version":\#(v),"received_at":\#(receivedAt),"host":\#(host)\#(id),"payload":\#(payload)}"#.utf8)
    }
}

extension AgentFixture {
    /// A short, unique socket path in the per-user temp dir (`sun_path` holds 103 chars).
    static func temporarySocketURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("om-\(UUID().uuidString.prefix(8)).sock")
    }
}

/// A blocking POSIX client mirroring what `omelette-hook` does.
enum AgentSocketTestClient {
    /// Connects to `path`. nil when nothing listens there.
    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    /// Fire-and-forget or one-shot request: connect, write, half-close, optionally wait
    /// for one reply line. Returns the reply without its newline, or nil when the
    /// connection fails, nothing is written, or no reply arrives within `replyTimeout`
    /// (pass 0 to not wait).
    @discardableResult
    static func send(_ line: Data, to path: String, replyTimeout: TimeInterval = 1) -> String? {
        guard let fd = connect(to: path) else { return nil }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Half-close like the helper does (it closes outright when it wants no reply):
        // without it a line that carries no trailing "\n" would only reach the server
        // when its 1 s per-connection budget expires, i.e. after our own reply timeout.
        shutdown(fd, SHUT_WR)
        guard written == line.count, replyTimeout > 0 else { return nil }
        return readLine(fd, timeout: replyTimeout)
    }

    @discardableResult
    static func send(_ line: String, to path: String, replyTimeout: TimeInterval = 1) -> String? {
        send(Data(line.utf8), to: path, replyTimeout: replyTimeout)
    }

    /// A held request: connect, write the line (which must end in "\n") and keep the
    /// connection open exactly like the helper does for a `PermissionRequest` — no
    /// half-close, because an EOF after the line is what "the helper left" looks like
    /// to the server. Read the reply with `readLine`; close the fd yourself.
    static func open(_ line: Data, to path: String) -> Int32? {
        precondition(line.last == 0x0A, "a held line must end in a newline")
        guard let fd = connect(to: path) else { return nil }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { close(fd); return nil }
        return fd
    }
}

extension AgentFixture {
    /// An `AgentReply` wired to one end of a socketpair, and the other end for the
    /// test to read what was written. Close `peer` in the test.
    static func replyPair(requestID: String? = AgentFixture.requestID) -> (reply: AgentReply, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair failed: \(errno)")
        var one: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return (AgentReply(requestID: requestID, fd: fds[0]), fds[1])
    }
}

extension AgentSocketTestClient {
    /// Reads one line (without its "\n") from `fd`. nil when nothing arrives within
    /// `timeout` or the peer closed without sending.
    static func readLine(_ fd: Int32, timeout: TimeInterval = 1) -> String? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
