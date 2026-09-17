import XCTest
@testable import Omelette

/// Independent verification of the tmux jump package against
/// docs/superpowers/specs/2026-09-17-tmux-jump-design.md. Written from the spec and
/// the diff (main..HEAD on fix/tmux-jump), not from the executor's own tests — new
/// fixtures, new boundary values. tmux itself is never spawned; only the already-built
/// `omelette-hook` binary is spawned (same technique `TmuxHookWireTests` uses), and
/// `TmuxJump` / `HostWalk` are exercised with injected runners and process tables.

// MARK: - TmuxAddress.parse on odd $TMUX values

final class TmuxAddressVerificationTests: XCTestCase {
    func testASocketPathContainingSpacesStillParses() {
        // The socket lives under a per-user temp dir; nothing stops a path with a
        // space in it (e.g. a login name with a space), and the split is on commas
        // only, so spaces must ride straight through.
        XCTAssertEqual(
            TmuxAddress.parse(environment: [
                "TMUX": "/private/tmp/tmux server-501/default,4200,0",
                "TMUX_PANE": "%3",
            ]),
            TmuxAddress(socketPath: "/private/tmp/tmux server-501/default", serverPID: 4200, pane: "%3")
        )
    }

    func testExtraCommasBeyondTheThirdFieldAreIgnored() {
        // tmux 3.7c writes exactly three fields; a future tmux that writes more must
        // not break the parse, and nothing past field two is ever read.
        XCTAssertEqual(
            TmuxAddress.parse(environment: [
                "TMUX": "/tmp/s,4200,0,extra,even,more,fields",
                "TMUX_PANE": "%9",
            ]),
            TmuxAddress(socketPath: "/tmp/s", serverPID: 4200, pane: "%9")
        )
    }

    func testATmuxValueWithNoCommaAtAllIsNotAnAddress() {
        // Fewer than two fields: nothing to read a pid out of.
        XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": "/tmp/s-with-no-comma", "TMUX_PANE": "%3"]))
    }

    func testNonNumericServerPIDsAreRejectedInSeveralShapes() {
        for raw in ["/tmp/s,abc,0", "/tmp/s,42.0,0", "/tmp/s,0x4200,0", "/tmp/s, 4200,0", "/tmp/s,4200 ,0"] {
            XCTAssertNil(TmuxAddress.parse(environment: ["TMUX": raw, "TMUX_PANE": "%3"]), raw)
        }
    }

    func testAPaneOfJustAPercentWithNoDigitsIsNotAnAddress() {
        // The exact shape the spec calls out: "%" with nothing after it.
        XCTAssertFalse(TmuxAddress.isPaneID("%"))
        XCTAssertNil(TmuxAddress.parse(environment: [
            "TMUX": "/private/tmp/tmux-501/default,45727,0", "TMUX_PANE": "%",
        ]))
    }

    func testALeadingZeroInThePaneIDIsStillAllDigits() {
        // isPaneID only checks "% then ASCII digits" — a leading zero is not excluded,
        // and nothing downstream needs the pane parsed as a number.
        XCTAssertTrue(TmuxAddress.isPaneID("%007"))
        XCTAssertEqual(
            TmuxAddress.parse(environment: [
                "TMUX": "/private/tmp/tmux-501/default,45727,0", "TMUX_PANE": "%007",
            ]),
            TmuxAddress(socketPath: "/private/tmp/tmux-501/default", serverPID: 45727, pane: "%007")
        )
    }
}

// MARK: - The envelope the built helper writes

/// Spawns the real `omelette-hook` binary the app ships (never tmux) with an injected
/// environment, and reads the raw line off the socket before the decoder touches it —
/// "absent" and "null" both decode to nil, so only the raw bytes can tell them apart.
final class TmuxHookWireVerificationTests: XCTestCase {
    private func runHelperCapturingRawLine(tmux: [String: String]) throws -> String {
        let listener = try RawEnvelopeListener()
        defer { listener.close() }

        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = listener.path
        for key in ["TMUX", "TMUX_PANE"] { environment.removeValue(forKey: key) }
        for (key, value) in tmux { environment[key] = value }
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(AgentFixture.stop.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        return try XCTUnwrap(listener.wait(timeout: 3), "no bytes captured from the helper")
    }

    func testAMalformedPaneStillOmitsTheTmuxKeysRatherThanSendingAHalfAddress() throws {
        // $TMUX is well-formed but $TMUX_PANE is not a pane id at all: TmuxAddress.parse
        // must return nil, and the envelope must carry none of the three keys — never a
        // socket with no pane to go with it.
        let line = try runHelperCapturingRawLine(tmux: [
            "TMUX": "/private/tmp/tmux-501/default,\(getpid()),0",
            "TMUX_PANE": "pane-one",
        ])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
        let host = try XCTUnwrap(envelope["host"] as? [String: Any])
        XCTAssertNil(host["tmux_socket"], "\(host)")
        XCTAssertNil(host["tmux_pane"], "\(host)")
        XCTAssertNil(host["tmux_bin"], "\(host)")
        XCTAssertEqual(envelope["v"] as? Int, 2)
    }

    func testAWellFormedAddressKeepsTheWireVersionAtTwo() throws {
        // The three tmux keys are additive; a helper that does carry them must not
        // bump the version any more than a helper that doesn't.
        let line = try runHelperCapturingRawLine(tmux: [
            "TMUX": "/private/tmp/tmux-501/default,\(getpid()),0",
            "TMUX_PANE": "%4",
        ])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
        XCTAssertEqual(envelope["v"] as? Int, 2)
        let host = try XCTUnwrap(envelope["host"] as? [String: Any])
        XCTAssertEqual(host["tmux_socket"] as? String, "/private/tmp/tmux-501/default")
        XCTAssertEqual(host["tmux_pane"] as? String, "%4")
    }
}

/// A one-shot AF_UNIX listener that accepts one connection and returns the first
/// newline-terminated line untouched — same technique `TmuxHookWireTests` uses, kept
/// as an independent copy so this file never depends on that one's private type.
private final class RawEnvelopeListener: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let semaphore = DispatchSemaphore(value: 0)
    private var received: String?

    init() throws {
        path = AgentFixture.temporarySocketURL().path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "RawEnvelopeListener", code: Int(errno)) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "RawEnvelopeListener", code: Int(errno))
        }

        DispatchQueue.global().async { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { semaphore.signal(); return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while !data.contains(0x0A) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            Darwin.close(client)
            received = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
            semaphore.signal()
        }
    }

    func wait(timeout: TimeInterval) -> String? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return received
    }

    func close() {
        Darwin.close(fd)
        unlink(path)
    }
}

// MARK: - Route order, tmuxTarget, TmuxJump, HostWalk

final class TmuxJumpVerificationTests: XCTestCase {
    private func exists(_ paths: Set<String>) -> (String) -> Bool { { paths.contains($0) } }

    // MARK: route order

    func testTheFullPriorityLadderOnOneHostThatCarriesEverything() {
        // One host that could plausibly route four different ways at once: cmux ids,
        // a tmux address, a pid and a bundle id all present. The spec's order (cmux,
        // tmux, pid, finder) is tested here as one ladder, stripping one rung at a
        // time, rather than four hosts built in isolation.
        var host = AgentHostInfo(pid: 777, bundleID: "com.apple.Terminal", tty: "/dev/ttys020")
        host.cmuxWorkspace = "ws-1"
        host.cmuxSurface = "sf-1"
        host.cmuxSocket = "/tmp/cmux-ladder.sock"
        host.tmuxSocket = "/private/tmp/tmux-501/default"
        host.tmuxPane = "%5"
        host.tmuxBinary = "/opt/homebrew/bin/tmux"

        XCTAssertEqual(
            SessionActivator.route(for: host, tmuxBinaryExists: exists([])),
            .cmux(SessionActivator.CmuxTarget(workspace: "ws-1", surface: "sf-1", socketPath: "/tmp/cmux-ladder.sock"))
        )

        host.cmuxWorkspace = nil
        XCTAssertEqual(
            SessionActivator.route(for: host, tmuxBinaryExists: exists([])),
            .tmux(SessionActivator.TmuxTarget(socketPath: "/private/tmp/tmux-501/default", pane: "%5", binary: "/opt/homebrew/bin/tmux"))
        )

        host.tmuxPane = nil
        XCTAssertEqual(SessionActivator.route(for: host, tmuxBinaryExists: exists([])), .process(pid: 777))

        host.pid = nil
        XCTAssertEqual(SessionActivator.route(for: host, tmuxBinaryExists: exists([])), .finder)
    }

    // MARK: tmuxTarget

    func testTmuxTargetUsesTheReportedBinaryEvenWhenItIsNotOnDisk() {
        // "A reported binary is taken as it stands" — the disk is never consulted
        // when the helper already told us where tmux runs from.
        let host = AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys031",
                                  tmuxSocket: "/private/tmp/tmux-9/default", tmuxPane: "%2",
                                  tmuxBinary: "/usr/local/Cellar/tmux/3.7/bin/tmux")
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: host, binaryExists: exists([])),
            SessionActivator.TmuxTarget(socketPath: "/private/tmp/tmux-9/default", pane: "%2",
                                        binary: "/usr/local/Cellar/tmux/3.7/bin/tmux")
        )
    }

    func testTmuxTargetFallsBackInFallbackOrderWhenTheBinaryIsMissing() {
        let host = AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys031",
                                  tmuxSocket: "/private/tmp/tmux-9/default", tmuxPane: "%2", tmuxBinary: nil)
        // Only the last fallback exists: it must still be picked over nothing.
        XCTAssertEqual(
            SessionActivator.tmuxTarget(for: host, binaryExists: exists(["/usr/bin/tmux"]))?.binary,
            "/usr/bin/tmux"
        )
    }

    func testTmuxTargetIsNilWhenNoFallbackExistsAndNoBinaryWasReported() {
        let host = AgentHostInfo(pid: nil, bundleID: nil, tty: "/dev/ttys031",
                                  tmuxSocket: "/private/tmp/tmux-9/default", tmuxPane: "%2", tmuxBinary: nil)
        XCTAssertNil(SessionActivator.tmuxTarget(for: host, binaryExists: exists([])))
    }

    // MARK: TmuxJump argument lists

    func testBothArgumentListsPutDashSAndTheSocketBeforeTheCommandName() {
        let listArgs = TmuxJump.listClientsArguments(socketPath: "/tmp/sock-a", pane: "%6")
        XCTAssertEqual(listArgs[0], "-S")
        XCTAssertEqual(listArgs[1], "/tmp/sock-a")
        XCTAssertEqual(listArgs[2], "list-clients")

        let switchArgs = TmuxJump.switchClientArguments(socketPath: "/tmp/sock-a", pane: "%6", clientTTY: "/dev/ttys050")
        XCTAssertEqual(switchArgs[0], "-S")
        XCTAssertEqual(switchArgs[1], "/tmp/sock-a")
        XCTAssertEqual(switchArgs[2], "switch-client")
    }

    // MARK: pickClient

    func testTheLargestClientActivityWinsOverTwoOtherClients() {
        let output = "10\t/dev/ttys001\t100\n20\t/dev/ttys002\t500\n30\t/dev/ttys003\t300\n"
        XCTAssertEqual(TmuxJump.pickClient(from: output), TmuxJump.Client(pid: 20, tty: "/dev/ttys002"))
    }

    func testATieInClientActivityGoesToTheFirstLine() {
        // Ties go to the first line tmux printed — deterministic beats clever.
        let output = "10\t/dev/ttys001\t1789600000\n20\t/dev/ttys002\t1789600000\n"
        XCTAssertEqual(TmuxJump.pickClient(from: output), TmuxJump.Client(pid: 10, tty: "/dev/ttys001"))
    }

    func testEmptyOutputHasNoClient() {
        XCTAssertNil(TmuxJump.pickClient(from: ""))
    }

    func testMalformedLinesAreSkippedNotGuessed() {
        let output = """
        garbage-line-with-no-tabs
        0\t/dev/ttys009\t100
        \t/dev/ttys010\t200
        11\t\t300
        12\t/dev/ttys011\tnot-a-number
        13\t/dev/ttys012\t150
        """
        XCTAssertEqual(TmuxJump.pickClient(from: output), TmuxJump.Client(pid: 13, tty: "/dev/ttys012"))
    }

    // MARK: selectPane

    private let target = SessionActivator.TmuxTarget(
        socketPath: "/private/tmp/tmux-verify/default", pane: "%8", binary: "/opt/homebrew/bin/tmux"
    )

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [(binary: String, arguments: [String])] = []
        var all: [(binary: String, arguments: [String])] {
            lock.lock(); defer { lock.unlock() }
            return made
        }
        func record(_ binary: String, _ arguments: [String]) {
            lock.lock(); made.append((binary, arguments)); lock.unlock()
        }
    }

    func testSelectPaneCallsListClientsBeforeSwitchClient() async {
        let calls = CallRecorder()
        let client = await TmuxJump.selectPane(target) { binary, arguments in
            calls.record(binary, arguments)
            guard arguments.contains("list-clients") else { return "" }
            return "40\t/dev/ttys040\t1789600000\n"
        }
        XCTAssertEqual(client, TmuxJump.Client(pid: 40, tty: "/dev/ttys040"))
        XCTAssertEqual(calls.all.count, 2)
        XCTAssertTrue(calls.all[0].arguments.contains("list-clients"), "list-clients must run first")
        XCTAssertTrue(calls.all[1].arguments.contains("switch-client"))
        XCTAssertTrue(calls.all[1].arguments.contains("/dev/ttys040"), "switch-client must carry the picked client's tty")
    }

    func testAnEmptyClientListNeverCallsSwitchClient() async {
        let calls = CallRecorder()
        let client = await TmuxJump.selectPane(target) { binary, arguments in
            calls.record(binary, arguments)
            return ""
        }
        XCTAssertNil(client)
        XCTAssertEqual(calls.all.count, 1, "an empty list-clients answer must not be followed by switch-client")
    }

    func testARunnerThatReturnsNilNeverCallsSwitchClientEither() async {
        let calls = CallRecorder()
        let client = await TmuxJump.selectPane(target) { binary, arguments in
            calls.record(binary, arguments)
            return nil
        }
        XCTAssertNil(client)
        XCTAssertEqual(calls.all.count, 1, "list-clients itself failed; switch-client must never be attempted")
    }

    // MARK: tmuxScript uses the client tty, never the host tty

    func testTmuxScriptNeverContainsThePaneTTYEvenWhenItLooksSimilar() throws {
        // A pane tty that happens to share a prefix with the client tty must not fool a
        // naive substring check into thinking the pane tty leaked in.
        let client = TmuxJump.Client(pid: 55, tty: "/dev/ttys055")
        let source = try XCTUnwrap(SessionActivator.tmuxScript(bundleID: "com.googlecode.iterm2", client: client))
        XCTAssertTrue(source.contains("\"/dev/ttys055\""))
        XCTAssertFalse(source.contains("/dev/ttys05x"), "sanity: unrelated tty must not appear")
    }

    // MARK: HostWalk boundary and gap behaviour

    private func reader(_ table: [pid_t: ProcessRecord]) -> (pid_t) -> ProcessRecord? { { table[$0] } }

    func testAKnownBundleExactlyAtTheThirtySecondHopIsStillFound() {
        // hops < maxHops is checked before the pid is read, so the 32nd read (index 31
        // from a start pid at index 0) is the last one that happens at all.
        var table: [pid_t: ProcessRecord] = [:]
        for pid in pid_t(2)...pid_t(60) {
            table[pid] = ProcessRecord(parentPID: pid + 1, tty: nil, bundleID: pid == 33 ? "com.apple.Terminal" : nil)
        }
        let terminal = HostWalk.describe(from: 2, read: reader(table))
        XCTAssertEqual(terminal.bundleID, "com.apple.Terminal", "pid 33 is the 32nd process read from a start at pid 2")
        XCTAssertEqual(terminal.pid, 33)
    }

    func testABundleOneHopBeyondTheCapIsNeverSeen() {
        var table: [pid_t: ProcessRecord] = [:]
        for pid in pid_t(2)...pid_t(60) {
            table[pid] = ProcessRecord(parentPID: pid + 1, tty: nil, bundleID: pid == 34 ? "com.apple.Terminal" : nil)
        }
        let terminal = HostWalk.describe(from: 2, read: reader(table))
        XCTAssertNil(terminal.bundleID, "pid 34 would be the 33rd process read, past the 32-hop cap")
    }

    func testTheFirstNonNilTTYIsKeptEvenWhenTheStartingProcessHasNone() {
        // result.tty is set on the first record whose tty is non-nil, not simply the
        // very first record examined.
        let table: [pid_t: ProcessRecord] = [
            10: ProcessRecord(parentPID: 9, tty: nil, bundleID: nil),
            9: ProcessRecord(parentPID: 8, tty: "/dev/ttys070", bundleID: nil),
            8: ProcessRecord(parentPID: 1, tty: "/dev/ttys071", bundleID: "com.apple.Terminal"),
        ]
        XCTAssertEqual(HostWalk.describe(from: 10, read: reader(table)).tty, "/dev/ttys070")
    }

    func testAKnownBundleReemergingAfterAnUnrelatedKnownBundleStillExtendsTheOriginal() {
        // Documents actual behaviour for a shape the spec never describes directly:
        // the "outermost process of the same app" rule matches by bundle-id equality
        // wherever it recurs, not by contiguous ancestry, so a differently-known
        // bundle sitting between two occurrences of the first one does not break the
        // chain back to it.
        let table: [pid_t: ProcessRecord] = [
            10: ProcessRecord(parentPID: 9, tty: "/dev/ttys080", bundleID: nil),
            9: ProcessRecord(parentPID: 8, tty: nil, bundleID: "com.apple.Terminal"),
            8: ProcessRecord(parentPID: 7, tty: nil, bundleID: "com.microsoft.VSCode"),
            7: ProcessRecord(parentPID: 1, tty: nil, bundleID: "com.apple.Terminal"),
        ]
        let terminal = HostWalk.describe(from: 10, read: reader(table))
        XCTAssertEqual(terminal.bundleID, "com.apple.Terminal")
        XCTAssertEqual(terminal.pid, 7, "the outermost recurrence of the first known bundle id")
    }
}
