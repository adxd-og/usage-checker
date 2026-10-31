import XCTest
@testable import Omelette

/// Tester's verification of the fix round's C1 and C2 rulings (whole-branch review of 4.0, Codex):
/// every sub-table of an entry we own is folded or removed, in any position, CRLF too; our old
/// entry beside a `brioche` that is not ours reads as an old entry alone, Disable removes only
/// ours, Enable/Update reports the conflict and writes nothing.
///
/// Two sweeps carry most of it. One crosses every state of the old and the new entry (absent,
/// ours, ours from another home, somebody else's, unreadable), with and without a sub-table each,
/// in five orders, in LF and CRLF, and holds the status, Update and Disable to one oracle that is
/// written here and not read off the code. The other puts all of ours in every order.
final class MCPInstallerEntrySectionsVerificationTests: XCTestCase {
    private var root: URL!
    private let cli = "/Users/tester/Library/Application Support/UsageTracker/bin/brioche"
    private let oldCLI = "/Users/tester/Library/Application Support/UsageTracker/bin/omelette"
    private let otherOld = "/Users/other/Library/Application Support/UsageTracker/bin/omelette"
    private let otherNew = "/Users/other/Library/Application Support/UsageTracker/bin/brioche"
    private let foreignOld = "/opt/homebrew/bin/omelette"
    private let foreignNew = "/opt/homebrew/bin/brioche"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPInstallerEntrySectionsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var claudeURL: URL { root.appendingPathComponent(".claude.json") }
    private var codexURL: URL { root.appendingPathComponent("config.toml") }

    private func codexStatus() -> HookInstallStatus { MCPInstaller.codexStatus(configURL: codexURL, cliPath: cli) }
    private func claudeStatus() -> HookInstallStatus { MCPInstaller.claudeStatus(configURL: claudeURL, cliPath: cli) }
    private func codexText() throws -> String { try String(contentsOf: codexURL, encoding: .utf8) }
    private func codexBytes() throws -> Data { try Data(contentsOf: codexURL) }
    private func writeCodex(_ text: String) throws { try Data(text.utf8).write(to: codexURL) }

    private func headers(_ text: String) -> [[String]] {
        SettingsFile.lines(of: text).compactMap { MCPInstaller.codexHeaderKey($0) }
    }

    private func headerCount(_ text: String, _ key: [String]) -> Int {
        headers(text).filter { $0 == key }.count
    }

    /// Headers strictly below `key`.
    private func subTableCount(_ text: String, below key: [String]) -> Int {
        headers(text).filter { $0.count > key.count && $0.starts(with: key) }.count
    }

    private func table(_ header: String, command: String) -> String {
        "\(header)\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n\n"
    }

    private let omeletteEnv = "[mcp_servers.omelette.env]\nDEBUG = \"1\"\n\n"
    private let briocheEnv = "[mcp_servers.brioche.env]\nKEEP = \"1\"\n\n"
    private let xcode = "[mcp_servers.xcode]\ncommand = \"xcrun\"\n\n"
    private let zed = "[z]\na = 1\n"

    // MARK: - C1: deeper than one level, arrays of tables, lookalikes

    func testNestedAndArrayOfTablesSubTablesAreFoldedFromFarAway() throws {
        let nested = "[mcp_servers.omelette.env.inner]\nA = 1\n\n"
        let tools = "[[mcp_servers.omelette.tools]]\nname = \"x\"\n\n[[mcp_servers.omelette.tools]]\nname = \"y\"\n\n"
        try writeCodex(nested + xcode + table("[mcp_servers.omelette]", command: oldCLI) + zed + tools)
        XCTAssertEqual(codexStatus(), .outdated)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        let after = try codexText()
        XCTAssertEqual(subTableCount(after, below: ["mcp_servers", "omelette"]), 0, after)
        XCTAssertEqual(headerCount(after, ["mcp_servers", "omelette"]), 0, after)
        XCTAssertEqual(headerCount(after, MCPInstaller.codexKey), 1, after)
        XCTAssertEqual(headerCount(after, ["mcp_servers", "xcode"]), 1, after)
        XCTAssertEqual(headerCount(after, ["z"]), 1, after)
        XCTAssertFalse(after.contains("name = "), after)
        XCTAssertEqual(codexStatus(), .installed, after)
    }

    func testRemoveTakesNestedAndArrayOfTablesSubTablesAndNothingNearThem() throws {
        let keepers = "[mcp_servers.omelette-extra.env]\nX = \"1\"\n\n[mcp_servers.xcode.omelette]\nY = \"2\"\n\n[mcp_servers.omelette_x]\nZ = 3\n\n"
        let ours = "[mcp_servers.omelette.env.inner]\nA = 1\n\n"
            + table("[mcp_servers.omelette]", command: oldCLI)
            + "[[mcp_servers.omelette.tools]]\nname = \"x\"\n\n"
        try writeCodex(keepers + ours + zed)

        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(try codexText(), keepers + zed, "only ours goes, each piece with its own lines")
    }

    func testAKeyOnlyStartingLikeOursNeverFollowsUsEitherWay() throws {
        let lookalikes = "[mcp_servers.omelette-extra.env]\nX = \"1\"\n\n[mcp_servers.xcode.omelette]\nY = \"2\"\n\n"
        let old = table("[mcp_servers.omelette]", command: oldCLI)
        try writeCodex(lookalikes + old + zed)

        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)

        XCTAssertEqual(try codexText(), lookalikes + table("[mcp_servers.brioche]", command: cli) + zed)
    }

    func testSubTablesWithNoTableOfOursAreLeftAloneByDisable() throws {
        // Nobody's entry: Disable has nothing of ours to take, whatever its name suggests.
        let text = omeletteEnv + xcode + briocheEnv
        try writeCodex(text)
        XCTAssertEqual(codexStatus(), .notInstalled)
        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)
        XCTAssertEqual(try codexText(), text)
    }

    /// All of ours at once, in every order. Whatever the order, an Update leaves one current
    /// table, no sub-table of either name, the neighbours as they were, and a second Update changes
    /// nothing; Disable then leaves none of ours.
    func testEveryOrderOfBothEntriesAndTheirSubTablesFoldsToOne() throws {
        let pieces = [
            table("[mcp_servers.omelette]", command: oldCLI), omeletteEnv,
            table("[mcp_servers.brioche]", command: cli), briocheEnv,
            xcode, zed,
        ]
        var failures: [String] = []
        var runs = 0
        for order in permutations(Array(pieces.indices)) {
            runs += 1
            let crlf = runs % 4 == 0
            var text = order.map { pieces[$0] }.joined()
            if runs % 3 == 0, text.hasSuffix("\n") { text.removeLast() }
            if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
            try writeCodex(text)
            if codexStatus() != .outdated { failures.append("status \(codexStatus()) for \(order)") }
            do {
                try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
            } catch {
                failures.append("install threw \(error) for \(order)")
                continue
            }
            let after = try codexText()
            if subTableCount(after, below: ["mcp_servers", "omelette"]) != 0
                || headerCount(after, ["mcp_servers", "omelette"]) != 0
                || subTableCount(after, below: MCPInstaller.codexKey) != 0
                || headerCount(after, MCPInstaller.codexKey) != 1
                || headerCount(after, ["mcp_servers", "xcode"]) != 1
                || headerCount(after, ["z"]) != 1
                || after.contains("DEBUG") || after.contains("KEEP")
                || !after.contains("command = \"xcrun\"")
                || codexStatus() != .installed
                || after.utf8.last != UInt8(ascii: "\n")
                || (crlf && after.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            { failures.append("after install for \(order)\(crlf ? " (CRLF)" : ""):\n\(after)") }
            let once = try codexBytes()
            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
            if try codexBytes() != once { failures.append("second install changed the file for \(order)") }
            try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)
            let removed = try codexText()
            if headerCount(removed, MCPInstaller.codexKey) != 0
                || subTableCount(removed, below: ["mcp_servers"]) != 1   // xcode, which is not ours
                || headerCount(removed, ["mcp_servers", "xcode"]) != 1
                || headerCount(removed, ["z"]) != 1
                || codexStatus() != .notInstalled
            { failures.append("after Disable for \(order):\n\(removed)") }
        }
        XCTAssertEqual(runs, 720)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(runs) orders failed; first:\n\(failures.prefix(3).joined(separator: "\n----\n"))")
    }

    // MARK: - The sweep over the old entry, the new one and their sub-tables

    private enum Kind: CaseIterable, CustomStringConvertible {
        case absent, ours, oursElsewhere, foreign, unreadable
        var description: String {
            switch self {
            case .absent: "absent"
            case .ours: "ours"
            case .oursElsewhere: "oursElsewhere"
            case .foreign: "foreign"
            case .unreadable: "unreadable"
            }
        }
        var isOurs: Bool { self == .ours || self == .oursElsewhere }
    }

    private func codexTable(_ name: String, _ kind: Kind, mine: String, elsewhere: String, foreign: String) -> String? {
        let header = "[mcp_servers.\(name)]"
        switch kind {
        case .absent: return nil
        case .ours: return table(header, command: mine)
        case .oursElsewhere: return table(header, command: elsewhere)
        case .foreign: return table(header, command: foreign)
        case .unreadable: return "\(header)\nargs = [\"mcp\"]\n\n"
        }
    }

    /// What the status row says, from the rule alone: the old entry that is ours decides the row
    /// unless a current one of ours stands beside it (then Update has two to fold); a current one
    /// that is not ours decides it only when no old one of ours is there to be reached.
    private func expectedStatus(
        legacy: Kind, legacySub: Bool, current: Kind, currentSub: Bool, foreignCommand: String, unreadable: String
    ) -> HookInstallStatus {
        let legacyStatus: HookInstallStatus? = legacy.isOurs ? (legacy == .ours && !legacySub ? .installed : .outdated) : nil
        switch current {
        case .absent: return legacyStatus ?? .notInstalled
        case .unreadable: return legacyStatus ?? .conflict(unreadable)
        case .foreign: return legacyStatus ?? .conflict(foreignCommand)
        case .ours, .oursElsewhere:
            if legacy.isOurs { return .outdated }
            return current == .ours && !currentSub ? .installed : .outdated
        }
    }

    func testTheOldTableBesideTheNewOneInEveryStateAndOrderAgreesAcrossStatusUpdateAndDisable() throws {
        var failures: [String] = []
        var runs = 0
        for legacy in Kind.allCases {
            for current in Kind.allCases {
                for legacySub in [false, true] where legacy != .absent || !legacySub {
                    for currentSub in [false, true] where current != .absent || !currentSub {
                        var pieces: [String] = []
                        if let t = codexTable("omelette", legacy, mine: oldCLI, elsewhere: otherOld, foreign: foreignOld) {
                            pieces.append(t)
                            if legacySub { pieces.append(omeletteEnv) }
                        }
                        if let t = codexTable("brioche", current, mine: cli, elsewhere: otherNew, foreign: foreignNew) {
                            pieces.append(t)
                            if currentSub { pieces.append(briocheEnv) }
                        }
                        pieces += [xcode, zed]
                        let count = pieces.count
                        let orders: [[Int]] = [
                            Array(0..<count), Array((0..<count).reversed()),
                            (0..<count).map { ($0 + 1) % count }, (0..<count).map { ($0 + 2) % count },
                            (0..<count).map { ($0 + 3) % count },
                        ]
                        for (index, order) in orders.enumerated() {
                            runs += 1
                            let crlf = index % 2 == 1
                            var text = order.map { pieces[$0] }.joined()
                            if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
                            let context = "legacy \(legacy)\(legacySub ? "+sub" : ""), current \(current)\(currentSub ? "+sub" : ""), order \(order)\(crlf ? " CRLF" : "")"
                            try check(text, legacy, legacySub, current, currentSub, context, &failures)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(runs, 400)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(runs) failed; first:\n\(failures.prefix(4).joined(separator: "\n----\n"))")
    }

    private func check(
        _ text: String, _ legacy: Kind, _ legacySub: Bool, _ current: Kind, _ currentSub: Bool,
        _ context: String, _ failures: inout [String]
    ) throws {
        let crlf = text.contains("\r\n")
        try writeCodex(text)
        let before = try codexBytes()

        let status = codexStatus()
        let expected = expectedStatus(
            legacy: legacy, legacySub: legacySub, current: current, currentSub: currentSub,
            foreignCommand: foreignNew, unreadable: MCPInstaller.codexUnreadableTableReason
        )
        if status != expected { failures.append("status \(status), expected \(expected): \(context)") }

        // Disable reaches exactly what the row calls ours.
        try MCPInstaller.removeCodex(configURL: codexURL, cliPath: cli)
        let removed = try codexText()
        let touched = try codexBytes() != before
        let ours = legacy.isOurs || current.isOurs
        if touched != ours { failures.append("Disable \(touched ? "changed" : "left") the file, ours is \(ours): \(context)") }
        if CommandLineSettingsText.showsDisableButton(status) != ours {
            failures.append("Disable button \(CommandLineSettingsText.showsDisableButton(status)) with ours \(ours): \(context)")
        }
        // Nothing of ours is left, and everything that is not ours is.
        let leftover = headers(removed).filter { $0.starts(with: ["mcp_servers", "omelette"]) || $0.starts(with: MCPInstaller.codexKey) }
        let keptLegacy = !legacy.isOurs && legacy != .absent
        let keptCurrent = !current.isOurs && current != .absent
        let expectedLeft = (keptLegacy ? 1 + (legacySub ? 1 : 0) : 0) + (keptCurrent ? 1 + (currentSub ? 1 : 0) : 0)
        if leftover.count != expectedLeft { failures.append("after Disable \(leftover.count) tables of that name, expected \(expectedLeft): \(context)\n\(removed)") }
        if headerCount(removed, ["mcp_servers", "xcode"]) != 1 || headerCount(removed, ["z"]) != 1 {
            failures.append("a neighbour went with Disable: \(context)\n\(removed)")
        }
        if crlf, removed.replacingOccurrences(of: "\r\n", with: "").contains("\n") {
            failures.append("Disable left a bare LF in a CRLF file: \(context)\n\(removed.debugDescription)")
        }

        // Update, from the arrangement as it was.
        try writeCodex(text)
        let blocked = current == .foreign || current == .unreadable
        do {
            try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
            if blocked { failures.append("Update went through beside a table that is not ours: \(context)") }
        } catch {
            if !blocked { failures.append("Update threw \(error): \(context)") }
            if try codexBytes() != before { failures.append("a refused Update changed the file: \(context)") }
            return
        }
        let after = try codexText()
        if headerCount(after, MCPInstaller.codexKey) != 1 { failures.append("Update left \(headerCount(after, MCPInstaller.codexKey)) tables: \(context)\n\(after)") }
        if codexStatus() != .installed { failures.append("status after Update \(codexStatus()): \(context)\n\(after)") }
        if subTableCount(after, below: MCPInstaller.codexKey) != 0 { failures.append("a sub-table stayed behind the new table: \(context)\n\(after)") }
        let legacyLeft = headers(after).filter { $0.starts(with: ["mcp_servers", "omelette"]) }.count
        let expectedLegacyLeft = legacy.isOurs ? 0 : (legacy == .absent ? 0 : 1 + (legacySub ? 1 : 0))
        if legacyLeft != expectedLegacyLeft { failures.append("Update left \(legacyLeft) old tables, expected \(expectedLegacyLeft): \(context)\n\(after)") }
        if headerCount(after, ["mcp_servers", "xcode"]) != 1 || headerCount(after, ["z"]) != 1 || !after.contains("command = \"xcrun\"") {
            failures.append("a neighbour went with Update: \(context)\n\(after)")
        }
        if after.utf8.last != UInt8(ascii: "\n") { failures.append("no final line ending after Update: \(context)") }
        if crlf, after.replacingOccurrences(of: "\r\n", with: "").contains("\n") {
            failures.append("Update left a bare LF in a CRLF file: \(context)\n\(after.debugDescription)")
        }
        let once = try codexBytes()
        try MCPInstaller.installCodex(configURL: codexURL, cliPath: cli)
        if try codexBytes() != once { failures.append("a second Update changed the file: \(context)") }
    }

    // MARK: - C2 on Claude's side, the same crossing

    private func claudeEntry(_ kind: Kind, mine: String, elsewhere: String, foreign: String) -> [String: Any]? {
        switch kind {
        case .absent: return nil
        case .ours: return ["type": "stdio", "command": mine, "args": ["mcp"]]
        case .oursElsewhere: return ["type": "stdio", "command": elsewhere, "args": ["mcp"]]
        case .foreign: return ["type": "stdio", "command": foreign, "args": ["mcp"]]
        case .unreadable: return ["args": ["mcp"]]
        }
    }

    private func writeClaude(_ servers: [String: Any]) throws {
        let file: [String: Any] = ["numStartups": 7, "mcpServers": servers]
        try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys]).write(to: claudeURL)
    }

    private func claudeFile() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
    }

    func testTheOldEntryBesideTheNewOneInEveryStateAgreesAcrossStatusUpdateAndDisable() throws {
        var failures: [String] = []
        for legacy in Kind.allCases {
            for current in Kind.allCases {
                var servers: [String: Any] = ["other": ["type": "stdio", "command": "/usr/bin/other"]]
                if let e = claudeEntry(legacy, mine: oldCLI, elsewhere: otherOld, foreign: foreignOld) { servers["omelette"] = e }
                if let e = claudeEntry(current, mine: cli, elsewhere: otherNew, foreign: foreignNew) { servers["brioche"] = e }
                let context = "legacy \(legacy), current \(current)"
                try writeClaude(servers)
                let before = try Data(contentsOf: claudeURL)

                let status = claudeStatus()
                let expected = expectedStatus(
                    legacy: legacy, legacySub: false, current: current, currentSub: false,
                    foreignCommand: foreignNew, unreadable: MCPInstaller.claudeUnreadableReason
                )
                if status != expected { failures.append("status \(status), expected \(expected): \(context)") }

                let ours = legacy.isOurs || current.isOurs
                if CommandLineSettingsText.showsDisableButton(status) != ours {
                    failures.append("Disable button \(CommandLineSettingsText.showsDisableButton(status)) with ours \(ours): \(context)")
                }
                try MCPInstaller.removeClaude(configURL: claudeURL, cliPath: cli)
                let removedData = try Data(contentsOf: claudeURL)
                if (removedData != before) != ours { failures.append("Disable \(removedData != before ? "changed" : "left") the file, ours is \(ours): \(context)") }
                let afterDisable = (try claudeFile()["mcpServers"] as? [String: Any]) ?? [:]
                if afterDisable["omelette"] != nil, legacy.isOurs { failures.append("Disable left our old entry: \(context)") }
                if afterDisable["brioche"] != nil, current.isOurs { failures.append("Disable left our new entry: \(context)") }
                if legacy != .absent, !legacy.isOurs, afterDisable["omelette"] == nil { failures.append("Disable took an old entry that is not ours: \(context)") }
                if current != .absent, !current.isOurs, afterDisable["brioche"] == nil { failures.append("Disable took a new entry that is not ours: \(context)") }
                if afterDisable["other"] == nil { failures.append("Disable took another server: \(context)") }

                try writeClaude(servers)
                let blocked = current == .foreign || current == .unreadable
                do {
                    try MCPInstaller.installClaude(configURL: claudeURL, cliPath: cli)
                    if blocked { failures.append("Update went through beside an entry that is not ours: \(context)") }
                } catch {
                    if !blocked { failures.append("Update threw \(error): \(context)") }
                    if try Data(contentsOf: claudeURL) != before { failures.append("a refused Update changed the file: \(context)") }
                    continue
                }
                let file = try claudeFile()
                let map = (file["mcpServers"] as? [String: Any]) ?? [:]
                if SettingsFile.canonicalJSON(map["brioche"] as? [String: Any] ?? [:]) != SettingsFile.canonicalJSON(MCPInstaller.claudeTemplate(cliPath: cli)) {
                    failures.append("Update left a different entry under brioche: \(context)")
                }
                if legacy.isOurs, map["omelette"] != nil { failures.append("Update left our old entry beside the new: \(context)") }
                if legacy != .absent, !legacy.isOurs, map["omelette"] == nil { failures.append("Update took an old entry that is not ours: \(context)") }
                if map["other"] == nil || file["numStartups"] as? Int != 7 { failures.append("Update lost something of the file: \(context)") }
                if claudeStatus() != .installed { failures.append("status after Update \(claudeStatus()): \(context)") }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failed; first:\n\(failures.prefix(4).joined(separator: "\n----\n"))")
    }

    // MARK: -

    private func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[Int]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }
}
