import XCTest
@testable import Omelette

/// Independent verification of the oversized-payload fix in `HookHelper/main.swift`
/// (session's design, 2026-11-02, "oversized hook payloads are dropped whole"):
/// a line within 64 KB is sent unchanged; past it the payload keeps only the keys the
/// app reads, `tool_input` is shrunk as before and never invented; a PermissionRequest
/// is still held; a payload that stays over 64 KB is dropped with exit 0.
///
/// Two receivers: a raw socket listener that captures the exact wire line (to measure
/// the 64 KB boundary and to see which payload keys were sent), and the real
/// `AgentEventServer` (to see what the app would make of it and to hold a request).
final class OmeletteHookOversizedPayloadVerificationTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var events: [AgentEvent] = []
        var replies: [AgentReply] = []
    }

    /// Accepts connections on a unix socket and records every line it reads, raw.
    private final class RawListener: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [Data] = []
        private var running = true
        private let fd: Int32
        let path: String

        init(path: String) throws {
            self.path = path
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw NSError(domain: "RawListener", code: 1) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "RawListener", code: 2) }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                buffer[bytes.count] = 0
            }
            unlink(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw NSError(domain: "RawListener", code: 3) }
            let thread = Thread { [self] in acceptLoop() }
            thread.start()
        }

        private func acceptLoop() {
            while true {
                lock.lock(); let live = running; lock.unlock()
                if !live { return }
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pollFD, 1, 50) > 0 else { continue }
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { continue }
                var data = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                var clientPoll = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                while poll(&clientPoll, 1, 1000) > 0 {
                    let count = read(client, &chunk, chunk.count)
                    if count <= 0 { break }
                    data.append(chunk, count: count)
                    if data.last == 0x0A { break }
                }
                Darwin.close(client)
                lock.lock(); captured.append(data); lock.unlock()
            }
        }

        var lines: [Data] { lock.lock(); defer { lock.unlock() }; return captured }

        func waitForLine(timeout: TimeInterval = 3) -> Data? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let first = lines.first { return first }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }

        func stop() {
            lock.lock(); running = false; lock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
            Darwin.close(fd)
            unlink(path)
        }
    }

    private var socketURL: URL!
    private var server: AgentEventServer?
    private var raw: RawListener?
    private let box = Box()

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledHelperURL.path),
            "omelette-hook missing at \(AgentPaths.bundledHelperURL.path)"
        )
    }

    override func tearDown() {
        server?.stop()
        server = nil
        raw?.stop()
        raw = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func startServer() throws {
        let box = self.box
        let server = AgentEventServer(socketURL: socketURL) { event, reply in box.events.append(event); box.replies.append(reply) }
        try server.start()
        self.server = server
    }

    private func startRaw() throws -> RawListener {
        let listener = try RawListener(path: socketURL.path)
        raw = listener
        return listener
    }

    private struct Launched {
        let process: Process
        let stdout: Pipe
    }

    private func launchHelper(stdin input: String? = nil, arguments: [String] = [], decisionTimeout: TimeInterval? = nil) throws -> Launched {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        if let decisionTimeout { environment[AgentPaths.decisionTimeoutEnvironmentKey] = String(decisionTimeout) }
        environment.removeValue(forKey: ClaudeRenewalMarker.environmentKey)
        process.environment = environment
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        return Launched(process: process, stdout: stdout)
    }

    private func finish(_ launched: Launched) -> (status: Int32, stdout: String) {
        let output = launched.stdout.fileHandleForReading.readDataToEndOfFile()
        launched.process.waitUntilExit()
        return (launched.process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @discardableResult
    private func runHelper(stdin input: String? = nil, arguments: [String] = []) throws -> Int32 {
        finish(try launchHelper(stdin: input, arguments: arguments)).status
    }

    private func waitOnMain(timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func waitForEvents(_ count: Int, timeout: TimeInterval = 3) -> Bool {
        waitOnMain(timeout: timeout) { box.events.count >= count }
    }

    private func envelope(of line: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private func payload(of line: Data) throws -> [String: Any] {
        try XCTUnwrap(try envelope(of: line)["payload"] as? [String: Any])
    }

    private let bulk = String(repeating: "x", count: 100 * 1024)

    // MARK: - Within 64 KB: byte for byte as today

    func testAPayloadWithinTheLimitIsForwardedWithEveryKeyIncludingTheUnreadOnes() throws {
        let listener = try startRaw()
        let medium = String(repeating: "m", count: 30 * 1024)
        let input = AgentFixture.claude(
            "Stop", sessionID: "sess-small",
            extra: #""last_assistant_message":"\#(medium)","stop_hook_active":false,"extra_thing":{"a":[1,2,3]}"#
        )

        XCTAssertEqual(try runHelper(stdin: input), 0)
        let line = try XCTUnwrap(listener.waitForLine())
        XCTAssertLessThan(line.count, 64 * 1024)
        let sent = try payload(of: line)
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: sent), NSDictionary(dictionary: original), "within the limit nothing is dropped or added")
        XCTAssertNotNil(sent["transcript_path"])
        XCTAssertNotNil(sent["last_assistant_message"])
        XCTAssertNil(sent["tool_input"], "and no tool_input appears from nowhere")
    }

    func testACodexNotifyWithinTheLimitKeepsItsKebabCaseExtras() throws {
        let listener = try startRaw()
        let input = AgentFixture.codexTurnComplete

        XCTAssertEqual(try runHelper(arguments: ["--codex", input]), 0)
        let sent = try payload(of: try XCTUnwrap(listener.waitForLine()))
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: sent), NSDictionary(dictionary: original))
    }

    // MARK: - The boundary, measured on the wire

    /// A Stop line of exactly `target` bytes (newline included), found by probing and
    /// adjusting the padding: the line grows one byte per padding byte.
    private func waitForNewLine(_ listener: RawListener, after count: Int, timeout: TimeInterval = 3) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = listener.lines
            if lines.count > count { return lines[count] }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func measure(target: Int, padding: inout Int, listener: RawListener) throws -> (Data, Int)? {
        for _ in 0..<60 {
            let before = listener.lines.count
            let input = AgentFixture.claude("Stop", extra: #""last_assistant_message":"\#(String(repeating: "p", count: padding))""#)
            XCTAssertEqual(try runHelper(stdin: input), 0)
            guard let line = waitForNewLine(listener, after: before) else { return nil }
            if line.count == target { return (line, padding) }
            // A shrunk line (small) means we overshot because `received_at` printed longer: back off.
            padding += line.count < target / 2 ? -1 : target - line.count
        }
        return nil
    }

    func testALineOfExactlySixtyFourKilobytesIsSentWholeAndOneByteMoreIsShrunk() throws {
        let listener = try startRaw()

        var start = 60 * 1024
        guard let (exact, padding) = try measure(target: 64 * 1024, padding: &start, listener: listener) else {
            XCTFail("could not construct a line of exactly 65536 bytes")
            return
        }
        XCTAssertEqual(exact.count, 64 * 1024)
        let sentWhole = try payload(of: exact)
        XCTAssertEqual((sentWhole["last_assistant_message"] as? String)?.count, padding, "at the limit nothing is shrunk")
        XCTAssertNotNil(sentWhole["transcript_path"])

        // One more byte of padding: the unshrunk line would be 65537 bytes, so it shrinks.
        // `received_at` is a Double whose printed length wobbles by a byte or two between
        // runs, so a try can land back at <= 65536 and be sent whole; whenever a line is
        // sent whole it must be within the limit, and over a few tries one must shrink.
        var shrankOnce = false
        for _ in 0..<12 {
            let before = listener.lines.count
            let over = AgentFixture.claude("Stop", extra: #""last_assistant_message":"\#(String(repeating: "p", count: padding + 1))""#)
            XCTAssertEqual(try runHelper(stdin: over), 0)
            let line = try XCTUnwrap(waitForNewLine(listener, after: before))
            let sent = try payload(of: line)
            if sent["last_assistant_message"] == nil {
                shrankOnce = true
                XCTAssertNil(sent["transcript_path"])
                XCTAssertEqual(sent["hook_event_name"] as? String, "Stop")
                XCTAssertEqual(sent["session_id"] as? String, "sess-1")
                break
            }
            XCTAssertLessThanOrEqual(line.count, 64 * 1024, "a line sent whole is never over the limit")
        }
        XCTAssertTrue(shrankOnce, "a line one byte past the limit is shrunk")
    }

    // MARK: - What survives the shrink

    func testAnOversizedClaudePayloadKeepsExactlyTheKeysTheAppReads() throws {
        let listener = try startRaw()
        let input = AgentFixture.claude(
            "PreToolUse", sessionID: "sess-keys",
            extra: #""tool_name":"Bash","tool_input":{"command":"ls","description":"List"},"notification_type":"permission_prompt","agent_id":"agent-3","agent_type":"Explore","tool_response":{"x":"\#(bulk)"},"prompt":"hello","message":"m","tool_use_id":"toolu_1""#
        )

        XCTAssertEqual(try runHelper(stdin: input), 0)
        let sent = try payload(of: try XCTUnwrap(listener.waitForLine()))
        XCTAssertEqual(
            Set(sent.keys),
            ["hook_event_name", "session_id", "tool_name", "tool_input", "notification_type", "agent_id", "cwd"]
        )
        XCTAssertEqual(sent["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(sent["session_id"] as? String, "sess-keys")
        XCTAssertEqual(sent["tool_name"] as? String, "Bash")
        XCTAssertEqual(sent["notification_type"] as? String, "permission_prompt")
        XCTAssertEqual(sent["agent_id"] as? String, "agent-3")
        XCTAssertEqual(sent["cwd"] as? String, "/Users/me/Desktop/Usage tracker")
        let toolInput = try XCTUnwrap(sent["tool_input"] as? [String: Any])
        XCTAssertEqual(toolInput["command"] as? String, "ls")
        XCTAssertEqual(toolInput["_omelette_truncated"] as? Bool, true)
    }

    func testAnOversizedPayloadWithoutAToolInputGainsNeitherAToolInputNorTheTruncationFlag() throws {
        let listener = try startRaw()
        let input = AgentFixture.claude("SessionStart", extra: #""source":"startup","blob":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: input), 0)
        let envelope = try envelope(of: try XCTUnwrap(listener.waitForLine()))
        let sent = try XCTUnwrap(envelope["payload"] as? [String: Any])
        XCTAssertNil(sent["tool_input"])
        XCTAssertNil(sent["source"])
        // The envelope itself is untouched by the shrink.
        XCTAssertEqual(envelope["v"] as? Int, 2)
        XCTAssertEqual(envelope["source"] as? String, "claude")
        XCTAssertNotNil(envelope["host"])
        XCTAssertNotNil(envelope["received_at"])
    }

    func testAnOversizedCodexNotifyKeepsTypeThreadIDAndCwdOnlyAndKeepsItsTransport() throws {
        let listener = try startRaw()
        let input = #"{"type":"agent-turn-complete","thread-id":"thr-keys","turn-id":"turn-2","cwd":"/Users/me/Orion","input-messages":["\#(bulk)"],"last-assistant-message":"Done."}"#

        XCTAssertEqual(try runHelper(arguments: ["--codex", input]), 0)
        let envelope = try envelope(of: try XCTUnwrap(listener.waitForLine()))
        let sent = try XCTUnwrap(envelope["payload"] as? [String: Any])
        XCTAssertEqual(Set(sent.keys), ["type", "thread-id", "cwd"])
        XCTAssertEqual(sent["thread-id"] as? String, "thr-keys")
        XCTAssertEqual(envelope["source"] as? String, "codex")
        XCTAssertEqual(envelope["transport"] as? String, "notify")
    }

    func testAnOversizedCodexHookKeepsItsHookTransport() throws {
        let listener = try startRaw()
        let input = AgentFixture.codexHook("Stop", extra: #""last_assistant_message":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: input, arguments: ["--codex-hook"]), 0)
        let envelope = try envelope(of: try XCTUnwrap(listener.waitForLine()))
        XCTAssertEqual(envelope["transport"] as? String, "hook")
        XCTAssertEqual(envelope["source"] as? String, "codex")
        XCTAssertNil((envelope["payload"] as? [String: Any])?["last_assistant_message"])
    }

    /// Bytes, not characters, decide the limit: 40 000 two-byte characters are 80 KB.
    func testAMultiByteStringPastTheLimitInBytesStillShrinksAndArrives() throws {
        try startServer()
        let wide = String(repeating: "é", count: 40_000)
        let input = AgentFixture.claude("Stop", sessionID: "sess-wide", extra: #""last_assistant_message":"\#(wide)""#)

        XCTAssertEqual(try runHelper(stdin: input), 0)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.kind, .stop)
        XCTAssertEqual(box.events.first?.sessionID, "sess-wide")
    }

    // MARK: - Differential: oversized == small, as the app sees it

    /// The same event with and without 100 KB of an unread key: what the app derives
    /// from it (kind, session, cwd, tool name, headline, subagent flag, source) must
    /// be identical. Tool events also get the app's own truncation notice, which is
    /// the designed difference and so is left out of the comparison.
    func testEveryHookEventDecodesTheSameWithAndWithoutAnOversizedUnreadKey() throws {
        struct Case { let name: String; let stdin: String?; let arguments: [String]; let padded: String? ; let paddedArguments: [String] }
        let blob = #""zz_unread_bulk":"\#(bulk)""#
        func claudeCase(_ event: String, _ extra: String) -> Case {
            Case(name: "claude \(event) \(extra.prefix(30))",
                 stdin: AgentFixture.claude(event, extra: extra), arguments: [],
                 padded: AgentFixture.claude(event, extra: extra.isEmpty ? blob : extra + "," + blob), paddedArguments: [])
        }
        func codexCase(_ event: String, _ extra: String) -> Case {
            Case(name: "codex \(event)",
                 stdin: AgentFixture.codexHook(event, extra: extra), arguments: ["--codex-hook"],
                 padded: AgentFixture.codexHook(event, extra: extra.isEmpty ? blob : extra + "," + blob), paddedArguments: ["--codex-hook"])
        }
        let cases: [Case] = [
            claudeCase("SessionStart", #""source":"startup""#),
            claudeCase("UserPromptSubmit", #""prompt":"fix the ring""#),
            claudeCase("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"xcodegen generate","description":"Regenerate the project"}"#),
            claudeCase("PostToolUse", #""tool_name":"Read","tool_input":{"file_path":"/tmp/Big.swift"},"tool_response":{"content":"ok"}"#),
            claudeCase("Notification", #""message":"x","notification_type":"permission_prompt""#),
            claudeCase("Notification", #""message":"x","notification_type":"idle_prompt""#),
            claudeCase("Notification", #""message":"x","notification_type":"auth_success""#),
            claudeCase("Stop", #""stop_hook_active":false"#),
            claudeCase("SessionEnd", #""reason":"exit""#),
            claudeCase("PreToolUse", #""agent_id":"agent-7","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"AgentEvent"}"#),
            claudeCase("SubagentStop", #""agent_id":"agent-7""#),
            claudeCase("PreToolUse", #""tool_name":"mcp__omelette__get_usage""#),
            codexCase("SessionStart", ""),
            codexCase("UserPromptSubmit", #""prompt":"go""#),
            codexCase("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"cargo test","description":"Run the tests"}"#),
            codexCase("PostToolUse", #""tool_name":"Bash","tool_input":{"command":"cargo test"},"tool_response":"ok""#),
            codexCase("Stop", ""),
            codexCase("SessionEnd", ""),
            Case(name: "codex notify", stdin: nil, arguments: ["--codex", AgentFixture.codexTurnComplete],
                 padded: nil, paddedArguments: ["--codex", #"{"type":"agent-turn-complete","thread-id":"thr-9","turn-id":"turn-2","cwd":"/Users/me/Desktop/Orion Gate","input-messages":["\#(bulk)"],"last-assistant-message":"Done."}"#]),
        ]

        try startServer()
        func run(_ stdin: String?, _ arguments: [String]) throws -> AgentEvent {
            let before = box.events.count
            XCTAssertEqual(try runHelper(stdin: stdin, arguments: arguments), 0)
            XCTAssertTrue(waitForEvents(before + 1), "no event for \(arguments) \(stdin?.prefix(60) ?? "")")
            return box.events[before]
        }
        for entry in cases {
            let small = try run(entry.stdin, entry.arguments)
            let big = try run(entry.padded, entry.paddedArguments)
            XCTAssertEqual(big.kind, small.kind, entry.name)
            XCTAssertEqual(big.source, small.source, entry.name)
            XCTAssertEqual(big.sessionID, small.sessionID, entry.name)
            XCTAssertEqual(big.cwd, small.cwd, entry.name)
            XCTAssertEqual(big.toolName, small.toolName, entry.name)
            XCTAssertEqual(big.toolSummary, small.toolSummary, entry.name)
            XCTAssertEqual(big.isSubagent, small.isSubagent, entry.name)
            XCTAssertEqual(big.attention, small.attention, entry.name)
            if entry.stdin.map({ !$0.contains("tool_input") }) ?? true {
                XCTAssertEqual(big.toolDetail, small.toolDetail, "\(entry.name): no tool_input, so no truncation notice")
            }
        }
    }

    // MARK: - PermissionRequest stays held

    func testAnOversizedClaudePermissionRequestIsStillHeldWithItsRequestIDAndAnswered() throws {
        try startServer()
        let input = AgentFixture.claude(
            "PermissionRequest", sessionID: "sess-perm",
            extra: #""tool_name":"Edit","tool_input":{"file_path":"/Users/me/W.swift","old_string":"a","new_string":"b"},"tool_response":{"x":"\#(bulk)"}"#
        )
        let launched = try launchHelper(stdin: input)

        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.kind, .permissionRequested)
        XCTAssertEqual(event.toolSummary, "Edit W.swift")
        let reply = try XCTUnwrap(box.replies.first)
        XCTAssertEqual(reply.requestID?.count, 32)
        XCTAssertEqual(event.requestID, reply.requestID)
        XCTAssertFalse(reply.isSettled)
        reply.send(.allow)

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"# + "\n")
    }

    func testAnOversizedCodexPermissionRequestIsStillHeldAndDenied() throws {
        try startServer()
        let input = AgentFixture.codexHook(
            "PermissionRequest",
            extra: #""tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"},"zz":"\#(bulk)""#
        )
        let launched = try launchHelper(stdin: input, arguments: ["--codex-hook"])

        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.source, .codex)
        XCTAssertEqual(event.kind, .permissionRequested)
        let reply = try XCTUnwrap(box.replies.first)
        XCTAssertEqual(reply.requestID?.count, 32)
        reply.send(.deny)

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.contains(#""behavior":"deny""#))
    }

    func testAnOversizedPermissionRequestWithoutADecisionTimesOutQuietly() throws {
        try startServer()
        let input = AgentFixture.claude(
            "PermissionRequest",
            extra: #""tool_name":"Edit","tool_input":{"file_path":"/Users/me/W.swift"},"zz":"\#(bulk)""#
        )
        let started = Date()
        let launched = try launchHelper(stdin: input, decisionTimeout: 0.3)

        XCTAssertTrue(waitForEvents(1))
        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "", "no decision, nothing printed")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - Still too big after the shrink

    func testAPayloadStillOverTheLimitAfterTheShrinkIsDroppedWithExitZero() throws {
        try startServer()
        let hugeCwd = String(repeating: "d", count: 70 * 1024)
        let input = AgentFixture.claude("Stop", cwd: hugeCwd, extra: #""last_assistant_message":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: input), 0)
        XCTAssertFalse(waitForEvents(1, timeout: 0.7), "nothing reaches the app")
        XCTAssertEqual(box.events.count, 0)
    }

    /// Dropped means not sent: a receiver that reads whatever arrives sees nothing, not
    /// an over-limit line that only the app's own size check throws away.
    func testAPayloadStillOverTheLimitAfterTheShrinkIsNeverPutOnTheWire() throws {
        let listener = try startRaw()
        let hugeCwd = String(repeating: "d", count: 70 * 1024)
        let input = AgentFixture.claude("Stop", cwd: hugeCwd, extra: #""last_assistant_message":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: input), 0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(listener.lines.count, 0, "the helper sends nothing it knows is over 64 KB")
    }

    /// The shrunk line is allowed up to and including 65536 bytes: the drop is for a line
    /// "over 64 KB", not "at 64 KB". Built with an unread bulk key and a cwd sized so the
    /// kept payload alone makes the line exactly 65536 bytes.
    func testAShrunkLineOfExactlySixtyFourKilobytesIsStillSent() throws {
        let listener = try startRaw()
        var cwdLength = 50 * 1024
        var found: Data?
        for _ in 0..<60 {
            let before = listener.lines.count
            let input = AgentFixture.claude("Stop", cwd: String(repeating: "d", count: cwdLength), extra: #""last_assistant_message":"\#(bulk)""#)
            XCTAssertEqual(try runHelper(stdin: input), 0)
            if let line = waitForNewLine(listener, after: before, timeout: 0.4) {
                if line.count == 64 * 1024 { found = line; break }
                cwdLength += 64 * 1024 - line.count
            } else {
                cwdLength -= 1   // overshot: the shrunk line was over the limit and dropped
            }
        }
        let line = try XCTUnwrap(found, "could not build a shrunk line of exactly 65536 bytes")
        let sent = try payload(of: line)
        XCTAssertNil(sent["last_assistant_message"], "it was shrunk")
        XCTAssertEqual((sent["cwd"] as? String)?.count, cwdLength)
    }

    func testAnAbsurdSessionIDOnAPermissionRequestExitsZeroWithoutHolding() throws {
        try startServer()
        let hugeID = String(repeating: "s", count: 70 * 1024)
        let input = AgentFixture.claude("PermissionRequest", sessionID: hugeID, extra: #""tool_name":"Edit","tool_input":{"file_path":"/a"}"#)
        let started = Date()

        let run = finish(try launchHelper(stdin: input))

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "dropped, not held")
        XCTAssertEqual(box.events.count, 0)
    }

    func testAnOversizedPayloadWhoseToolInputIsNotAnObjectStillArrives() throws {
        try startServer()
        let input = AgentFixture.claude("PreToolUse", extra: #""tool_name":"Bash","tool_input":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: input), 0)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.kind, .toolStarted)
        XCTAssertEqual(box.events.first?.toolName, "Bash")
    }
}
