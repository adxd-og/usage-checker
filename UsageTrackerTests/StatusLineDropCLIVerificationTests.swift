import XCTest
@testable import Omelette

/// End to end for P1: the built `omelette statusline` with a payload on stdin. EVERY
/// spawn sets `OMELETTE_STATUSLINE_DIR` to a temp folder (and `OMELETTE_STATUS_FILE`),
/// so nothing here can reach the real Application Support.
final class StatusLineDropCLIVerificationTests: XCTestCase {
    private var root: URL!
    private var dropURL: URL!
    private var statusURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineDropCLIVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dropURL = root.appendingPathComponent("inner/statusline", isDirectory: true)
        statusURL = root.appendingPathComponent("status.json")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: AgentPaths.bundledCLIURL.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: dropURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    struct Run: Equatable { let status: Int32; let stdout: Data; let stderr: Data }

    /// `dropDir` is always set; the home is a temp folder too, so even a missed override
    /// could not reach the real one.
    func run(_ stdin: String?, dropDir: URL? = nil, extra: [String: String] = [:]) throws -> Run {
        let p = Process()
        p.executableURL = AgentPaths.bundledCLIURL
        p.arguments = ["statusline", "--no-color"]
        var env = ProcessInfo.processInfo.environment
        env[StatusFile.environmentKey] = statusURL.path
        env[StatusLineDrop.environmentKey] = (dropDir ?? dropURL).path
        env["HOME"] = root.appendingPathComponent("fakehome").path
        env["CLAUDE_CONFIG_DIR"] = nil
        env.merge(extra) { _, new in new }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, stdout: o, stderr: e)
    }

    private func tree() -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
    }

    func testTheLineAndExitCodeAreByteIdenticalWithAndWithoutAWritableDrop() throws {
        // With a status.json absent the line is just the piped part; still a real line.
        let payload = StatusLineFixture.payload()
        let withDrop = try run(payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dropURL.appendingPathComponent(StatusLineFixture.sessionID + ".json").path))

        // Same payload, drop target unwritable (a file where the folder would be).
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let failing = try run(payload, dropDir: blocker.appendingPathComponent("sub"))

        // Same payload minus rate_limits: nothing written at all.
        let reference = try run(StatusLineFixture.payload(rateLimits: nil))

        XCTAssertEqual(withDrop, failing)
        XCTAssertEqual(withDrop.stdout, reference.stdout, "rate_limits must not change the printed line")
        XCTAssertEqual(withDrop.status, 0)
        XCTAssertEqual(failing.status, 0)
        XCTAssertTrue(withDrop.stderr.isEmpty)
        XCTAssertTrue(failing.stderr.isEmpty)
    }

    func testNoStdinNoWindowsNoSessionAndSpendLimitOnlyWriteNothing() throws {
        let cases: [String?] = [
            nil, "", "garbage",
            StatusLineFixture.payload(rateLimits: nil),
            StatusLineFixture.payload(rateLimits: #"{"spend_limit":{"used_percentage":50,"resets_at":99}}"#),
            #"{"model":{"display_name":"Opus"},"rate_limits":\#(StatusLineFixture.rateLimits)}"#,
        ]
        for c in cases {
            let r = try run(c)
            XCTAssertEqual(r.status, 0)
            XCTAssertTrue(r.stderr.isEmpty)
        }
        XCTAssertEqual(tree(), [], "no folder, no file: \(tree())")
    }

    func testHostileSessionIDsPrintTheSameLineAndWriteNothingOutsideTheFolder() throws {
        let baseline = try run(StatusLineFixture.payload())
        try? FileManager.default.removeItem(at: root.appendingPathComponent("inner"))
        let sentinel = root.appendingPathComponent("x.json")
        try Data("untouched".utf8).write(to: sentinel)
        let before = tree()
        for id in ["../x", "../../x", "a/b", "..", "é", "", String(repeating: "z", count: 4000), "a\\u0000b"] {
            let r = try run(StatusLineFixture.payload(sessionID: id))
            XCTAssertEqual(r.status, 0, id)
            XCTAssertEqual(r.stdout, baseline.stdout, id)
            XCTAssertTrue(r.stderr.isEmpty, id)
        }
        let after = tree()
        XCTAssertEqual(after.filter { !$0.hasPrefix("inner") }, before, "nothing new outside the drop folder")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        // "../x" from the drop folder lands in its parent, which this tree walk must see.
        XCTAssertEqual(
            after.filter { $0.hasPrefix("inner") && $0 != "inner" && !$0.hasPrefix("inner/statusline") }, [],
            "nothing beside the drop folder either"
        )
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dropURL.path)) ?? []
        XCTAssertEqual(leftovers, [], "hostile ids leave nothing, not even temp files")
    }

    func testConfigDirFromTheEnvironmentOrTheHomeDefault() throws {
        _ = try run(StatusLineFixture.payload(), extra: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("acct").path + "/"])
        let file = dropURL.appendingPathComponent(StatusLineFixture.sessionID + ".json")
        var r = try StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: Data(contentsOf: file))
        XCTAssertEqual(r.configDir, root.appendingPathComponent("acct").path)

        _ = try run(StatusLineFixture.payload())
        r = try StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: Data(contentsOf: file))
        // $HOME does not move `homeDirectoryForCurrentUser` (it asks the user database).
        XCTAssertEqual(r.configDir, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber, 0o600)
    }

    func testTheDecimalPercentReachesTheFileFromTheRealBinary() throws {
        _ = try run(StatusLineFixture.payload(rateLimits: #"{"five_hour":{"used_percentage":23.4,"resets_at":1788703200},"seven_day":{"used_percentage":100,"resets_at":1789065600}}"#))
        let file = dropURL.appendingPathComponent(StatusLineFixture.sessionID + ".json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("23.4"), text)
        let r = try StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: Data(text.utf8))
        XCTAssertEqual(r.fiveHour?.usedPercent, 23.4)
        XCTAssertEqual(r.sevenDay?.usedPercent, 100)
    }

    func testAnExistingLooseFolderIsTightenedByTheBinary() throws {
        try FileManager.default.createDirectory(at: dropURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dropURL.path)
        _ = try run(StatusLineFixture.payload())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dropURL.path)[.posixPermissions] as? NSNumber, 0o700)
    }

    func testConcurrentStatusLinesForOneSessionLeaveOneWholeFile() throws {
        let n = 24
        let lock = NSLock()
        var results: [Run] = []
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let payload = StatusLineFixture.payload(
                rateLimits: #"{"five_hour":{"used_percentage":\#(i).5,"resets_at":1788703200}}"#
            )
            do {
                let r = try self.run(payload)
                lock.lock(); results.append(r); lock.unlock()
            } catch {
                lock.lock(); failures.append("\(error)"); lock.unlock()
            }
        }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(results.count, n)
        XCTAssertTrue(results.allSatisfy { $0.status == 0 && $0.stderr.isEmpty })
        XCTAssertEqual(Set(results.map(\.stdout)).count, 1, "same line for every run")
        let names = try FileManager.default.contentsOfDirectory(atPath: dropURL.path)
        XCTAssertEqual(names, [StatusLineFixture.sessionID + ".json"], "no temp leftovers")
        let r = try StatusLineDrop.decoder.decode(
            StatusLineDrop.Reading.self,
            from: Data(contentsOf: dropURL.appendingPathComponent(names[0]))
        )
        let pct = try XCTUnwrap(r.fiveHour?.usedPercent)
        XCTAssertTrue((0..<n).contains { Double($0) + 0.5 == pct }, "\(pct) is one of the payloads, whole")
        XCTAssertNil(r.sevenDay, "no window of another payload mixed in")
    }
}
