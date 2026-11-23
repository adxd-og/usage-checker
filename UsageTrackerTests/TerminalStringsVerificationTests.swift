import XCTest
@testable import Omelette

/// Seeded property checks on the rule and on the JSON scan behind it, written from the
/// spec and not from the code: `clean` against a second, independent reading of the rule
/// over random scalar soups, and `cleaningStrings(inJSON:)` against `JSONDecoder` over
/// random documents spelled every way a writer may spell a string.
/// Spec: docs/superpowers/specs/2026-11-23-terminal-strings.md § Design 1 (one rule),
/// 2 (a line stays readable) and 3 (every string field, by construction).
final class TerminalStringsVerificationTests: XCTestCase {
    // MARK: - A seeded source of randomness

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_9B5D
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    /// Scalars of every kind the rule tells apart, and the neighbours that could confuse
    /// it: letters, marks, an emoji sequence's pieces, each space separator, the tab and
    /// the line breaks, every kind of removed control, the two joiners, tag characters and
    /// the astral format characters.
    private static let soup: [UInt32] = [
        0x61, 0x62, 0x3F, 0x22, 0x5C, 0x2F, 0x20, 0x20, 0xA0, 0x1680, 0x2003, 0x202F, 0x3000,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029,
        0x00, 0x07, 0x1B, 0x7F, 0x9B, 0xAD, 0x600, 0x61C, 0x180E, 0x200B, 0x200E, 0x202E, 0x2060, 0x2066,
        0xFEFF, 0xFFF9, 0x110BD, 0x1D173, 0xE0001, 0xE0067, 0xE007F,
        0x200C, 0x200D,
        0x301, 0x1F3F4, 0x1F468, 0x1F3FB, 0xFE0F, 0x4E2D, 0x5D0, 0xE000,
    ]

    private func string(_ values: [UInt32]) -> String {
        var view = String.UnicodeScalarView()
        for value in values { view.append(Unicode.Scalar(value)!) }
        return String(view)
    }

    private func values(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

    private func randomValues(_ random: inout Random, upTo length: Int) -> [UInt32] {
        (0..<random.below(length + 1)).map { _ in random.pick(Self.soup) }
    }

    // MARK: - clean against an independent reading of the rule

    private enum Kind { case visible, space, joiner, removed(breaksLine: Bool) }

    private func kind(_ value: UInt32) -> Kind {
        if value == 0x200C || value == 0x200D { return .joiner }
        switch Unicode.Scalar(value)!.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            let breaks = (0x09...0x0D).contains(value) || value == 0x85 || value == 0x2028 || value == 0x2029
            return .removed(breaksLine: breaks)
        case .spaceSeparator: return .space
        default: return .visible
        }
    }

    /// The rule as the spec words it, written run by run: a maximal run of removed
    /// scalars and joiners that holds a break or a tab leaves a space when a visible
    /// scalar stands on each side of it; the joiners stay where they are.
    private func reference(_ input: [UInt32]) -> [UInt32] {
        if input.isEmpty { return [] }
        let kinds = input.map(kind)
        var output: [UInt32] = []
        var sawVisible = false
        var index = 0
        func isVisible(_ i: Int) -> Bool { i >= 0 && i < kinds.count && { if case .visible = kinds[i] { return true }; return false }() }
        while index < input.count {
            switch kinds[index] {
            case .visible: output.append(input[index]); sawVisible = true; index += 1
            case .space: output.append(input[index]); index += 1
            case .joiner, .removed:
                var end = index
                var breaksLine = false
                var joiners: [UInt32] = []
                runLoop: while end < input.count {
                    switch kinds[end] {
                    case .joiner: joiners.append(input[end])
                    case .removed(let breaks): if breaks { breaksLine = true }
                    default: break runLoop
                    }
                    end += 1
                }
                output += joiners
                if breaksLine, isVisible(index - 1), isVisible(end) { output.append(0x20) }
                index = end
            }
        }
        guard sawVisible else { return [0x3F] }
        func isSpace(_ value: UInt32) -> Bool { if case .space = kind(value) { return true }; return false }
        while let first = output.first, isSpace(first) { output.removeFirst() }
        while let last = output.last, isSpace(last) { output.removeLast() }
        return output
    }

    func testCleanAgreesWithAnIndependentReadingOfTheRuleOnRandomSoups() {
        var random = Random(state: 20_261_123)
        for _ in 0..<60_000 {
            let input = randomValues(&random, upTo: 10)
            let cleaned = TerminalString.clean(string(input))
            XCTAssertEqual(values(cleaned), reference(input), "input \(input.map { String($0, radix: 16) })")
            XCTAssertFalse(cleaned.unicodeScalars.contains(where: TerminalString.isInvisible),
                           "a removed scalar is left in \(input.map { String($0, radix: 16) })")
        }
    }

    func testCleaningACleanedStringChangesNothingOnRandomSoups() {
        var random = Random(state: 7)
        for _ in 0..<60_000 {
            let input = randomValues(&random, upTo: 12)
            let once = TerminalString.clean(string(input))
            XCTAssertEqual(values(TerminalString.clean(once)), values(once), "input \(input.map { String($0, radix: 16) })")
        }
    }

    /// Nothing visible goes and nothing is made up: the visible scalars and the joiners
    /// of the output are the input's, in the order they came, and the only scalar the rule
    /// may add is one space where a line broke (or the "?" of a string with nothing left).
    func testCleanOnlyDropsScalarsAndAddsOneSpaceWhereALineBroke() {
        var random = Random(state: 99)
        for _ in 0..<40_000 {
            let input = randomValues(&random, upTo: 10)
            let cleaned = values(TerminalString.clean(string(input)))
            if cleaned == [0x3F], !input.contains(0x3F) { continue }
            func shown(_ list: [UInt32]) -> [UInt32] {
                list.filter { value in
                    switch kind(value) { case .visible, .joiner: return true; default: return false }
                }
            }
            XCTAssertEqual(shown(cleaned), shown(input), "input \(input.map { String($0, radix: 16) })")
        }
    }

    // MARK: - cleaningStrings(inJSON:) against JSONDecoder

    /// A JSON value as the decoder reads it: strings compared scalar by scalar, because
    /// `String ==` treats canonically equivalent texts as equal.
    private indirect enum Node: Decodable, Equatable {
        case null
        case flag(Bool)
        case number(Double)
        case text([UInt32])
        case list([Node])
        case map([[UInt32]: Node])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let value = try? c.decode(Bool.self) { self = .flag(value) }
            else if let value = try? c.decode(Double.self) { self = .number(value) }
            else if let value = try? c.decode(String.self) { self = .text(value.unicodeScalars.map(\.value)) }
            else if let value = try? c.decode([Node].self) { self = .list(value) }
            else {
                var map: [[UInt32]: Node] = [:]
                for (key, value) in try c.decode([String: Node].self) { map[key.unicodeScalars.map(\.value)] = value }
                self = .map(map)
            }
        }
    }

    private func decode(_ data: Data) -> Node? { try? JSONDecoder().decode(Node.self, from: data) }

    private func cleanedNode(_ node: Node) -> Node {
        let clean: ([UInt32]) -> [UInt32] = { self.values(TerminalString.clean(self.string($0))) }
        switch node {
        case .text(let text): return .text(clean(text))
        case .list(let list): return .list(list.map(cleanedNode))
        case .map(let map): return .map(Dictionary(uniqueKeysWithValues: map.map { (clean($0.key), cleanedNode($0.value)) }))
        default: return node
        }
    }

    /// False when two keys of one object clean to the same key (the decoder keeps one).
    private func keepsKeysApart(_ node: Node) -> Bool {
        switch node {
        case .list(let list): return list.allSatisfy(keepsKeysApart)
        case .map(let map):
            let keys = map.keys.map { values(TerminalString.clean(string($0))) }
            return Set(keys).count == keys.count && map.values.allSatisfy(keepsKeysApart)
        default: return true
        }
    }

    private func holdsARemovedScalar(_ node: Node) -> Bool {
        func bad(_ text: [UInt32]) -> Bool { text.contains { TerminalString.isInvisible(Unicode.Scalar($0)!) } }
        switch node {
        case .text(let text): return bad(text)
        case .list(let list): return list.contains(where: holdsARemovedScalar)
        case .map(let map): return map.contains { bad($0.key) || holdsARemovedScalar($0.value) }
        default: return false
        }
    }

    /// One string, spelled the way a writer may: scalars raw, as `\uXXXX` (either case, a
    /// surrogate pair above the BMP), as the short escapes, `/` escaped or not.
    private func spelled(_ text: [UInt32], _ random: inout Random) -> String {
        var out = "\""
        let style = random.below(4)   // 0 raw where allowed, 1 every scalar escaped, 2 and 3 mixed
        func escape(_ value: UInt32) -> String {
            let hex = random.below(2) == 0 ? "%04x" : "%04X"
            if value < 0x10000 { return "\\u" + String(format: hex, value) }
            let offset = value - 0x10000
            return "\\u" + String(format: hex, 0xD800 + (offset >> 10)) + "\\u" + String(format: hex, 0xDC00 + (offset & 0x3FF))
        }
        for value in text {
            switch value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x2F where random.below(2) == 0: out += "\\/"
            case 0..<0x20:
                let short: [UInt32: String] = [0x08: "\\b", 0x09: "\\t", 0x0A: "\\n", 0x0C: "\\f", 0x0D: "\\r"]
                if let form = short[value], random.below(2) == 0 { out += form } else { out += escape(value) }
            default:
                let raw = style == 0 || (style >= 2 && random.below(2) == 0)
                out += raw ? String(Unicode.Scalar(value)!) : escape(value)
            }
        }
        return out + "\""
    }

    private func spacing(_ random: inout Random) -> String {
        random.below(3) == 0 ? random.pick([" ", "\n", "\t", "\r\n", "  "]) : ""
    }

    private func document(_ depth: Int, _ random: inout Random) -> String {
        switch depth > 3 ? random.below(4) : random.below(6) {
        case 0: return random.pick(["0", "-1", "1.5e3", "2E-2", "123456789012", "true", "false", "null"])
        case 1, 2, 3: return spelled(randomValues(&random, upTo: 10), &random)
        case 4:
            let items = (0..<random.below(4)).map { _ in spacing(&random) + document(depth + 1, &random) + spacing(&random) }
            return "[" + items.joined(separator: ",") + "]"
        default:
            let members = (0..<random.below(4)).map { _ in
                spacing(&random) + spelled(randomValues(&random, upTo: 5), &random) + spacing(&random) + ":"
                    + spacing(&random) + document(depth + 1, &random) + spacing(&random)
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    /// Whatever spelling the writer chose for a string, what comes out decodes to the same
    /// document with every string cleaned by the rule, keys included, and holds no removed
    /// scalar: the scan and the decoder agree on where each string is and what it says.
    func testTheScanAndTheDecoderAgreeOnRandomDocumentsSpelledEveryWay() throws {
        var random = Random(state: 1_123)
        var compared = 0
        for _ in 0..<12_000 {
            var text = document(0, &random)
            if random.below(4) != 0 { text = "{\"k\":" + text + "}" }
            let input = Data(text.utf8)
            let read = try XCTUnwrap(decode(input), "the generator wrote invalid JSON: \(text.debugDescription)")
            let output = try XCTUnwrap(TerminalString.cleaningStrings(inJSON: input), text.debugDescription)
            let written = try XCTUnwrap(decode(output), "the output is not JSON: \(text.debugDescription)")
            XCTAssertFalse(holdsARemovedScalar(written), text.debugDescription)
            guard keepsKeysApart(read) else { continue }
            XCTAssertEqual(written, cleanedNode(read), text.debugDescription)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 10_000)
    }

    /// Hostile bytes: a document with one byte changed, added, dropped or cut off. The scan
    /// may refuse it or clean it, but when what it hands on decodes, no string of it holds a
    /// removed scalar, and a document the decoder reads is never refused for a reason of
    /// the scan's own (it may be refused for bytes the decoder tolerates and the scan does
    /// not: a string of a duplicate key that is never read).
    func testNoMutatedDocumentDecodesToARemovedScalar() {
        var random = Random(state: 424_242)
        let bytes: [UInt8] = [0x22, 0x5C, 0x75, 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C, 0x00, 0x1B, 0x80, 0xC2, 0x9B, 0xED, 0xEF, 0x2F, 0x2A, 0x0A, 0x20, 0xFF]
        var decodedAfterMutation = 0
        for _ in 0..<40_000 {
            var data = Array(document(0, &random).utf8)
            for _ in 0..<(1 + random.below(2)) where !data.isEmpty {
                let i = random.below(data.count)
                switch random.below(4) {
                case 0: data[i] = random.pick(bytes)
                case 1: data.insert(random.pick(bytes), at: i)
                case 2: data.remove(at: i)
                default: data = Array(data.prefix(i))
                }
            }
            guard let output = TerminalString.cleaningStrings(inJSON: Data(data)), let written = decode(output) else { continue }
            decodedAfterMutation += 1
            XCTAssertFalse(holdsARemovedScalar(written), String(decoding: data, as: UTF8.self).debugDescription)
        }
        XCTAssertGreaterThan(decodedAfterMutation, 1_000, "the mutations leave enough documents for the check to mean something")
    }

    // MARK: - Hand-picked arrangements of quotes and backslashes

    private func cleanedText(_ json: String) -> String? {
        TerminalString.cleaningStrings(inJSON: Data(json.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A string of printable ASCII needs no look at its scalars, and DEL is not printable:
    /// a raw DEL (JSON allows it unescaped) is removed from a string that holds nothing else
    /// out of the ordinary.
    func testARawDeleteCharacterInAnOtherwisePlainStringIsRemoved() throws {
        let output = try XCTUnwrap(cleanedText("{\"a\":\"x\u{7F}y\",\"b\":\"\u{7F}\"}"))
        XCTAssertEqual(output, #"{"a":"xy","b":"?"}"#)
    }

    /// A space at one end of an otherwise plain string is trimmed whichever end it is at.
    func testASpaceAtOnlyOneEndOfAPlainStringIsTrimmed() throws {
        XCTAssertEqual(cleanedText(#"{"a":" lead","b":"trail ","c":"in side"}"#), #"{"a":"lead","b":"trail","c":"in side"}"#)
    }

    /// Outside a string only JSON's own bytes may stand. A comment made of bytes JSON does use
    /// for numbers and literals (`// 1`) is still a comment, and is refused as one.
    func testACommentOutsideAStringIsRefusedWhateverItIsWrittenWith() {
        XCTAssertNil(cleanedText(#"{"a":1} // 1"#))
        XCTAssertNil(cleanedText(#"/* 1 */ {"a":1}"#))
        XCTAssertNil(cleanedText(#"{"a":1,/* 1 */"b":2}"#))
    }

    /// A backslash at the end of a string is an escaped backslash; the quote after it
    /// closes the string, and the next string is found where it really starts.
    func testABackslashAtTheEndOfAStringDoesNotSwallowTheQuoteThatClosesIt() throws {
        let json = #"["a\\","b‮","c\\\"d​","\\"]"#
        let output = try XCTUnwrap(cleanedText(json))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(output.utf8)), ["a\\", "b", "c\\\"d", "\\"])
    }

    /// A tag character spelled as its surrogate pair, and one from the musical block, go
    /// like the raw scalars do; a flag keeps its base.
    func testAstralFormatCharactersSpelledAsSurrogatePairsAreRemoved() throws {
        let json = #"{"a":"🏴󠁧󠁿","b":"x𝅳y","c":"󠀁"}"#
        let output = try XCTUnwrap(cleanedText(json))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(output.utf8)),
                       ["a": "\u{1F3F4}", "b": "xy", "c": "?"])
    }
}
