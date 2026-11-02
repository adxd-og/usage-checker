import XCTest
@testable import Omelette

/// Verification of P1 (spec 2026-11-02 Claude limits from the status line, § Design › Wire):
/// the payload shapes `rate_limits` is read from, and the places the drop will and will
/// not write. Every write goes to a temp folder; `home` is never the real one.
final class StatusLineDropVerificationTests: XCTestCase {
    private var root: URL!
    private var dropURL: URL!
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineDropVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The drop folder sits one level down so "nothing outside it" is observable in `root`.
        dropURL = root.appendingPathComponent("inner/statusline", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func parsed(_ json: String) -> StatusLineInput { StatusLineInput.parse(Data(json.utf8)) }

    private func limits(_ json: String) -> StatusLineInput.RateLimits? {
        parsed(#"{"session_id":"s","rate_limits":\#(json)}"#).rateLimits
    }

    @discardableResult
    private func write(_ input: StatusLineInput, environment: [String: String] = [:]) -> StatusLineDrop.Outcome {
        StatusLineDrop.write(input, to: dropURL, now: now, environment: environment, home: home)
    }

    /// Every path under `root`, relative, sorted.
    private func tree() -> [String] {
        let e = FileManager.default.enumerator(atPath: root.path)
        return (e?.allObjects as? [String] ?? []).sorted()
    }

    private func readBack(_ name: String) throws -> StatusLineDrop.Reading {
        try StatusLineDrop.decoder.decode(
            StatusLineDrop.Reading.self, from: Data(contentsOf: dropURL.appendingPathComponent(name))
        )
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    // MARK: - Parsing shapes

    func testAPercentOfZeroAndOfExactlyAHundredAreWindows() throws {
        let r = try XCTUnwrap(limits(#"{"five_hour":{"used_percentage":0,"resets_at":100},"seven_day":{"used_percentage":100.0,"resets_at":200}}"#))
        XCTAssertEqual(r.fiveHour?.usedPercent, 0)
        XCTAssertEqual(r.sevenDay?.usedPercent, 100)
    }

    func testNegativeAndOverflowingPercentsAreClamped() throws {
        let r = try XCTUnwrap(limits(#"{"five_hour":{"used_percentage":-3.5,"resets_at":100},"seven_day":{"used_percentage":1e9,"resets_at":200}}"#))
        XCTAssertEqual(r.fiveHour?.usedPercent, 0)
        XCTAssertEqual(r.sevenDay?.usedPercent, 100)
    }

    func testNullBooleanAndGarbageFieldsCostOnlyTheirOwnWindow() {
        let good = #""seven_day":{"used_percentage":12.3,"resets_at":500}"#
        let bad = [
            #"{"used_percentage":null,"resets_at":100}"#,
            #"{"used_percentage":true,"resets_at":100}"#,
            #"{"used_percentage":false,"resets_at":100}"#,
            #"{"used_percentage":"abc","resets_at":100}"#,
            #"{"used_percentage":[1],"resets_at":100}"#,
            #"{"used_percentage":{"x":1},"resets_at":100}"#,
            #"{"used_percentage":5,"resets_at":null}"#,
            #"{"used_percentage":5,"resets_at":true}"#,
            #"{"used_percentage":5,"resets_at":"soon"}"#,
            #"{"used_percentage":5}"#,
            #"{"resets_at":5}"#,
            #"{}"#, #"[]"#, #""text""#, "7", "null", "true",
        ]
        for window in bad {
            let r = limits(#"{"five_hour":\#(window),\#(good)}"#)
            XCTAssertNil(r?.fiveHour, window)
            XCTAssertEqual(r?.sevenDay?.usedPercent, 12.3, "neighbour must survive: \(window)")
        }
    }

    func testNumericStringsAreNumbersAndDecimalsAreKept() throws {
        let r = try XCTUnwrap(limits(#"{"five_hour":{"used_percentage":" 37.5 ","resets_at":"1788703200"}}"#))
        XCTAssertEqual(r.fiveHour?.usedPercent, 37.5)
        XCTAssertEqual(r.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_788_703_200))
        XCTAssertNil(r.sevenDay)
    }

    func testRateLimitsOfTheWrongTypeOrWithOnlySpendLimitAreNil() {
        for raw in ["null", "[]", #""x""#, "5", "true", "{}",
                    #"{"spend_limit":{"used_percentage":50,"resets_at":100}}"#,
                    #"{"five_hour":null,"seven_day":null,"spend_limit":{}}"#] {
            XCTAssertNil(limits(raw), raw)
        }
    }

    func testASessionIDThatIsNotAStringIsNoSessionID() {
        for raw in ["123", "null", "true", "[]", "{}", #""   ""#, #""""#] {
            XCTAssertNil(parsed(#"{"session_id":\#(raw)}"#).sessionID, raw)
        }
        XCTAssertNil(parsed("{}").sessionID)
    }

    func testTheCountersParseFromTheirNestedPlaceAndAsStrings() {
        let a = parsed(#"{"cost":{"total_api_duration_ms":"1500.5"},"prompt_id":"p","version":" 2.1.316 "}"#)
        XCTAssertEqual(a.totalAPIDurationMs, 1500.5)
        XCTAssertEqual(a.promptID, "p")
        XCTAssertEqual(a.version, "2.1.316")
        XCTAssertNil(parsed(#"{"total_api_duration_ms":5}"#).totalAPIDurationMs, "it lives under cost")
        XCTAssertNil(parsed(#"{"cost":{"total_api_duration_ms":true}}"#).totalAPIDurationMs)
        XCTAssertNil(parsed(#"{"cost":[1]}"#).totalAPIDurationMs)
    }

    func testRateLimitsDoNotDisturbTheRestOfThePayload() {
        let input = parsed(#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42},"rate_limits":"junk"}"#)
        XCTAssertEqual(input.model, "Opus")
        XCTAssertEqual(input.contextUsedPercent, 42)
        XCTAssertNil(input.rateLimits)
    }

    // MARK: - What a hostile id can reach

    func testHostileSessionIDsWriteNothingAndTouchNothingOutsideTheFolder() throws {
        // A sentinel where "../x" would land if the id climbed out.
        let sentinel = dropURL.deletingLastPathComponent().appendingPathComponent("x.json")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: sentinel)
        let rootSentinel = root.appendingPathComponent("x.json")
        try Data("untouched".utf8).write(to: rootSentinel)
        let before = tree()

        let ids = ["../x", "../../x", "a/b", "/abs", "..", ".", "-/../x", "é", "ｓｅｓｓ", "a\u{0}b", "a\nb",
                   "x.json", "a b", "a;b", "a*b", "~", "a\\b", "😀", "١٢٣", "\u{202E}fdp"]
        for id in ids {
            let payload = #"{"session_id":\#(String(decoding: try JSONSerialization.data(withJSONObject: [id], options: []), as: UTF8.self).dropFirst().dropLast()),"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#
            let outcome = write(parsed(payload))
            XCTAssertNotEqual(outcome, .written, "id \(id.debugDescription)")
        }
        XCTAssertEqual(tree(), before, "nothing created anywhere")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        XCTAssertEqual(try String(contentsOf: rootSentinel, encoding: .utf8), "untouched")
    }

    func testAnEmptyOrBlankSessionIDWritesNothing() {
        for id in ["", "   ", "\t"] {
            XCTAssertEqual(
                write(parsed(#"{"session_id":"\#(id)","rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#)),
                .nothingToWrite, id.debugDescription
            )
        }
        XCTAssertTrue(tree().isEmpty)
    }

    func testVeryLongSessionIDsAreNeverHalfWrittenAndLeaveNoTemporaryFile() throws {
        for length in [200, 240, 251, 300, 5000] {
            try? FileManager.default.removeItem(at: dropURL)
            let id = String(repeating: "a", count: length)
            let outcome = write(parsed(#"{"session_id":"\#(id)","rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dropURL.path)) ?? []
            XCTAssertTrue(files.allSatisfy { !$0.hasSuffix(".tmp") }, "len \(length): \(files)")
            if outcome == .written {
                XCTAssertEqual(files, [id + ".json"], "len \(length)")
            } else {
                XCTAssertEqual(files, [], "len \(length) outcome \(outcome)")
            }
        }
    }

    func testAnOrdinaryUUIDSessionIDIsAlwaysWritten() throws {
        let id = UUID().uuidString
        XCTAssertEqual(write(parsed(#"{"session_id":"\#(id)","rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#)), .written)
        XCTAssertEqual(try readBack(id + ".json").sessionID, id)
    }

    // MARK: - Replacement, modes, hostile targets

    private let ok = #"{"session_id":"sess-1","rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#

    func testAFolderThatAlreadyExistsWideOpenIsTightenedAndTheFileIsOwnerOnly() throws {
        try FileManager.default.createDirectory(at: dropURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dropURL.path)
        // An older reading left at 0666.
        let old = dropURL.appendingPathComponent("sess-1.json")
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: old.path)

        XCTAssertEqual(write(parsed(ok)), .written)

        XCTAssertEqual(try mode(dropURL), 0o700)
        XCTAssertEqual(try mode(old), 0o600, "the replacement carries its own mode, not the old file's")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dropURL.path), ["sess-1.json"])
    }

    func testAMalformedOlderFileIsReplacedByAWholeOne() throws {
        try FileManager.default.createDirectory(at: dropURL, withIntermediateDirectories: true)
        try Data("{\"v\":1,\"sess".utf8).write(to: dropURL.appendingPathComponent("sess-1.json"))
        XCTAssertEqual(write(parsed(ok)), .written)
        XCTAssertEqual(try readBack("sess-1.json").sessionID, "sess-1")
    }

    func testASymlinkAtTheTargetIsReplacedNotWrittenThrough() throws {
        try FileManager.default.createDirectory(at: dropURL, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("precious".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: dropURL.appendingPathComponent("sess-1.json"), withDestinationURL: outside
        )

        XCTAssertEqual(write(parsed(ok)), .written)

        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "precious")
        XCTAssertEqual(try readBack("sess-1.json").sessionID, "sess-1")
    }

    func testRepeatedWritesLeaveExactlyOneFileAndNoTemporaryNames() throws {
        for i in 0..<50 {
            let payload = #"{"session_id":"sess-1","cost":{"total_api_duration_ms":\#(i)},"rate_limits":{"five_hour":{"used_percentage":\#(i % 100),"resets_at":2}}}"#
            XCTAssertEqual(write(parsed(payload)), .written)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dropURL.path), ["sess-1.json"])
        XCTAssertEqual(try readBack("sess-1.json").totalAPIDurationMs, 49)
    }

    func testAReaderNeverSeesAHalfFileWhileWritersRace() throws {
        // Large-ish config_dir so each file is not trivially one page write.
        let env = ["CLAUDE_CONFIG_DIR": "/tmp/" + String(repeating: "c", count: 3000)]
        XCTAssertEqual(write(parsed(ok), environment: env), .written)
        let target = dropURL.appendingPathComponent("sess-1.json")
        let stop = NSLock(); var done = false
        let torn = NSLock(); var bad: [String] = []; var reads = 0
        let reader = Thread {
            while true {
                stop.lock(); let d = done; stop.unlock()
                if d { break }
                if let data = try? Data(contentsOf: target) {
                    torn.lock(); reads += 1
                    if (try? StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: data)) == nil {
                        bad.append("\(data.count) bytes")
                    }
                    torn.unlock()
                } else {
                    torn.lock(); bad.append("file vanished"); torn.unlock()
                }
            }
        }
        reader.start()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<60 {
                let payload = #"{"session_id":"sess-1","cost":{"total_api_duration_ms":\#(worker * 1000 + i)},"rate_limits":{"five_hour":{"used_percentage":\#(i),"resets_at":2}}}"#
                _ = StatusLineDrop.write(
                    StatusLineInput.parse(Data(payload.utf8)), to: dropURL, now: now, environment: env, home: home
                )
            }
        }
        stop.lock(); done = true; stop.unlock()
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(bad, [], "a reader saw a torn or missing file (\(reads) reads)")
        XCTAssertGreaterThan(reads, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dropURL.path), ["sess-1.json"])
        XCTAssertEqual(try mode(target), 0o600)
    }

    func testAPayloadWithoutSessionOrWindowsOrWithOnlySpendLimitCreatesNoFolder() {
        for payload in [
            #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":2}}}"#,
            #"{"session_id":"s1"}"#,
            #"{"session_id":"s1","rate_limits":{}}"#,
            #"{"session_id":"s1","rate_limits":{"spend_limit":{"used_percentage":5,"resets_at":9}}}"#,
            #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":null,"resets_at":9}}}"#,
            "", "not json", "[]", "null",
        ] {
            XCTAssertEqual(write(parsed(payload)), .nothingToWrite, payload)
        }
        XCTAssertTrue(tree().isEmpty, "not even the folder: \(tree())")
    }

    func testConfigDirFollowsTheEnvironmentOrTheDefaultInTheFile() throws {
        write(parsed(ok), environment: ["CLAUDE_CONFIG_DIR": "/tmp/acct-b/"])
        XCTAssertEqual(try readBack("sess-1.json").configDir, "/tmp/acct-b")
        write(parsed(ok), environment: [:])
        XCTAssertEqual(try readBack("sess-1.json").configDir, home.path + "/.claude")
        write(parsed(ok), environment: ["CLAUDE_CONFIG_DIR": ""])
        XCTAssertEqual(try readBack("sess-1.json").configDir, home.path + "/.claude")
    }

    func testDecimalAndClampedPercentsSurviveTheRoundTripThroughTheFile() throws {
        write(parsed(#"{"session_id":"sess-1","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1788703200},"seven_day":{"used_percentage":250,"resets_at":1789065600}}}"#))
        let r = try readBack("sess-1.json")
        XCTAssertEqual(r.fiveHour?.usedPercent, 23.5)
        XCTAssertEqual(r.sevenDay?.usedPercent, 100)
        XCTAssertEqual(r.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_788_703_200))
    }
}
