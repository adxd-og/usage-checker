import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Design › Credential, as the fix round's rulings A and A2
/// read it: `~/.vibe/.env` is read the way vibe reads it (python-dotenv 1.2.2, `dotenv_values`,
/// no interpolation), and a value with a control character inside (general category Cc) is no key
/// from its source, file or keychain. And § Surfaces, ruling B: the All providers widget lists at
/// most five providers and leaves the Admin API organisation out first.
///
/// Every expectation in the corpora below is `dotenv_values(stream=io.StringIO(text),
/// interpolate=False).get("MISTRAL_API_KEY")` from vibe's own interpreter (`python -I`, run on
/// strings, never on a file under `~/.vibe`), measured 2026-11-11, then trimmed the way the final
/// key is trimmed; nil is a key python-dotenv left absent, None or empty, or one ruling A2 refuses.
/// The corpora were also checked against the oracle on 1.1 million generated inputs, one per
/// Unicode scalar, and 250 thousand random token strings; those are not repeated here.
final class MistralProviderVerification2Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralProviderVerification2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func envFile(_ text: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".env")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Each row twice: the text on its own, and as the file on disk with a keychain behind it, so
    /// that nil also proves the keychain is asked.
    private func assertCorpus(_ rows: [(String, String, String?)], file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, text, expected) in rows {
            XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: text), expected, name, file: file, line: line)
            let reader = MistralCredentialReader(keychain: { "KEYCHAIN" }, envFileURL: try envFile(text))
            XCTAssertEqual(reader.read(), expected ?? "KEYCHAIN", name, file: file, line: line)
        }
    }

    // MARK: - The file as python-dotenv reads it


    func testLineEndsBlankLinesAndAMissingFinalNewlineAreReadAsPythonDotenvReadsThem() throws {
        try assertCorpus(Self.lineEndsCorpus)
    }

    func testExportInEveryFormIsReadAsPythonDotenvReadsIt() throws {
        try assertCorpus(Self.exportsCorpus)
    }

    func testQuotedUnquotedAndRepeatedNamesAreReadAsPythonDotenvReadsThem() throws {
        try assertCorpus(Self.namesCorpus)
    }

    func testAHashInEveryPositionIsReadAsPythonDotenvReadsIt() throws {
        try assertCorpus(Self.hashesCorpus)
    }

    func testRunsOfEqualsSignsAreReadAsPythonDotenvReadsThem() throws {
        try assertCorpus(Self.equalsCorpus)
    }

    func testQuotesInEveryPositionAndUnbalancedAcrossLinesAreReadAsPythonDotenvReadsThem() throws {
        try assertCorpus(Self.quotesCorpus)
    }

    func testEscapesInQuotedValuesAreDecodedAsPythonDotenvDecodesThem() throws {
        try assertCorpus(Self.escapesCorpus)
    }

    func testNonASCIIAndAstralCharactersSurviveAndOnlyPythonsBlanksAreBlanks() throws {
        try assertCorpus(Self.unicodeCorpus)
    }

    /// Ruling A2: a Cc character inside the value, whatever way it got there (raw, or an escape
    /// python-dotenv decodes), leaves no key from the file and the keychain is asked; at the edges
    /// of the value only the blanks python-dotenv and the final trim remove are removed.
    func testAControlCharacterInsideTheValueIsNoKeyFromTheFileAndTheKeychainIsAsked() throws {
        try assertCorpus(Self.controlsCorpus)
    }

    // MARK: - Ruling A2 at its edges, for either source

    /// Cc is exactly U+0000-001F, U+007F and U+0080-009F: DEL and the C1 controls are inside it,
    /// no-break space, line and paragraph separators, joiners and soft hyphens (not Cc) are not.
    func testOnlyTheControlCategoryRejectsAKeychainKey() {
        for scalar in [0x00, 0x09, 0x0A, 0x0B, 0x1B, 0x1F, 0x7F, 0x80, 0x85, 0x9F] as [UInt32] {
            let key = "kc" + String(Character(Unicode.Scalar(scalar)!)) + "key"
            XCTAssertNil(MistralCredentialReader.key(fromSecurityOutput: Data((key + "\n").utf8)), "U+\(String(scalar, radix: 16))")
        }
        for scalar in [0x20, 0xA0, 0xAD, 0x200D, 0x2028, 0x2029, 0x202E, 0xE000, 0x1F600] as [UInt32] {
            let key = "kc" + String(Character(Unicode.Scalar(scalar)!)) + "key"
            XCTAssertEqual(MistralCredentialReader.key(fromSecurityOutput: Data((key + "\n").utf8)), key, "U+\(String(scalar, radix: 16))")
        }
    }

    /// The file's refusal is not the end of the chain: a refused file value and then a refused
    /// keychain value is no key at all, and neither value is passed on.
    func testAControlCharacterInBothSourcesIsNoKey() throws {
        let url = try envFile("MISTRAL_API_KEY=\"a\nb\"\n")
        XCTAssertNil(MistralCredentialReader(keychain: { "k\u{7F}c" }, envFileURL: url).read())
        XCTAssertEqual(MistralCredentialReader(keychain: { "kc" }, envFileURL: url).read(), "kc")
    }

    /// The last assignment is the one vibe reads, and ruling A2 refuses it: the earlier good key
    /// does not stand in for it, the keychain is asked.
    func testALaterAssignmentWithAControlCharacterLeavesNoKeyFromTheFileEvenAfterAGoodOne() throws {
        let url = try envFile("MISTRAL_API_KEY=good\nMISTRAL_API_KEY=\"a\\tb\"\n")
        XCTAssertEqual(MistralCredentialReader(keychain: { "kc" }, envFileURL: url).read(), "kc")
    }

    // MARK: - Large inputs

    func testAFileOfThousandsOfLinesIsReadToTheKeyAtItsEnd() throws {
        let filler = (0..<5000).map { "A\($0)=\($0)\n" }.joined()
        try assertCorpus([
            ("5000 assignments then the key", filler + "MISTRAL_API_KEY=abc\n", "abc"),
            ("2000 blank lines then the key without a newline", String(repeating: "\n", count: 2000) + "MISTRAL_API_KEY=abc", "abc"),
            ("3000 CRLF comment lines then the key", String(repeating: "# c\r\n", count: 3000) + "MISTRAL_API_KEY=abc\r\n", "abc"),
            ("a key above 5001 lines of lone single quotes", "MISTRAL_API_KEY=abc\n" + (0..<5001).map { "B\($0)='\($0)\n" }.joined(), "abc"),
            ("a key above 5000 lines of lone single quotes", "MISTRAL_API_KEY=abc\n" + (0..<5000).map { "B\($0)='\($0)\n" }.joined(), "abc"),
            ("3000 lines each opening a double quote", String(repeating: "MISTRAL_API_KEY=\"a\n", count: 3000), nil),
            ("3001 lines each opening a double quote", String(repeating: "MISTRAL_API_KEY=\"a\n", count: 3001), nil),
            // 60 020 bytes: under the 64 KB the reader opens a file up to (4.3.0 release ruling).
            ("a long run of comments after the value", "MISTRAL_API_KEY=abc" + String(repeating: " #", count: 30_000) + "\n", "abc"),
        ])
    }

    func testVeryLongValuesAreKeptWhole() throws {
        // 60 000, not 100 000: the reader opens a file of at most 64 KB (4.3.0 release ruling).
        let plain = String(repeating: "x", count: 60_000)
        let escaped = String(repeating: "x\"", count: 20_000)
        try assertCorpus([
            ("60000 plain characters", "MISTRAL_API_KEY=" + plain + "\n", plain),
            ("20000 escaped quotes in double quotes", "MISTRAL_API_KEY=\"" + String(repeating: "x\\\"", count: 20_000) + "\"\n", escaped),
            ("20000 escaped quotes never closed fall back to the last", "MISTRAL_API_KEY=\"" + String(repeating: "x\\\"", count: 20_000) + "\n",
             String(repeating: "x\"", count: 19_999) + "x\\"),
        ])
    }

    // MARK: - Where the Swift port and vibe disagree

    /// python-dotenv keeps a byte order mark in the first name (`"\ufeffMISTRAL_API_KEY"`), so
    /// vibe has no key from such a file and uses the keychain; `String(contentsOf:)` drops the
    /// BOM, and the file's key would then be the one Brioche shows. Oracle: `dotenv_values(path)`
    /// on a file with the three bytes EF BB BF in front.
    func testAFileThatStartsWithAByteOrderMarkHasNoKeyOnItsFirstLineAsInVibe() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("MISTRAL_API_KEY=file-key\n".utf8)
        let url = directory.appendingPathComponent("bom.env")
        try bytes.write(to: url)
        XCTAssertEqual(MistralCredentialReader(keychain: { "KEYCHAIN" }, envFileURL: url).read(), "KEYCHAIN")
    }

    /// The Kelvin sign U+212A is canonically equivalent to `K` for Swift's `String ==`, not for
    /// python's `str ==`: in vibe `MISTRAL_API_\u{212A}EY` is another name and carries no key.
    func testANameThatOnlyLooksLikeTheKeysNameThroughUnicodeEquivalenceIsNotTheKey() throws {
        let text = "MISTRAL_API_\u{212A}EY=lookalike\n"
        XCTAssertNil(MistralCredentialReader.key(fromEnvFile: text))
        let reader = MistralCredentialReader(keychain: { "KEYCHAIN" }, envFileURL: try envFile(text))
        XCTAssertEqual(reader.read(), "KEYCHAIN")
    }

    // MARK: - The All providers widget, ruling B

    private func shown(_ ids: [String]) -> [String] {
        let services = ids.map { WidgetService(id: $0, name: $0, icon: "circle", plan: nil, buckets: []) }
        return WidgetEntryRules.allProvidersShown(WidgetSnapshot(services: services, updatedAt: Date(timeIntervalSince1970: 0))).map(\.id)
    }

    func testTheAdminOrganisationIsLeftOutWhereverItStandsWhenMoreThanFiveAreListed() {
        let others = ["claude", "codex", "antigravity", "grok", "mistral"]
        for position in 0...others.count {
            var ids = others
            ids.insert("anthropic-admin", at: position)
            XCTAssertEqual(shown(ids), others, "admin at \(position) of six")
        }
    }

    func testOnlyTheAdminOrganisationIsLeftOutAndTheCutKeepsTheAppsOrder() {
        XCTAssertEqual(
            shown(["claude", "anthropic-admin", "codex", "antigravity", "grok", "mistral", "extra", "more"]),
            ["claude", "codex", "antigravity", "grok", "mistral"]
        )
        XCTAssertEqual(
            shown(["anthropic-admin", "mistral", "grok", "extra", "more", "last"]),
            ["mistral", "grok", "extra", "more", "last"]
        )
    }

    func testFiveOrFewerListedKeepTheAdminOrganisationInPlace() {
        XCTAssertEqual(shown(["anthropic-admin"]), ["anthropic-admin"])
        XCTAssertEqual(shown(["claude", "anthropic-admin"]), ["claude", "anthropic-admin"])
        XCTAssertEqual(
            shown(["anthropic-admin", "claude", "codex", "grok", "mistral"]),
            ["anthropic-admin", "claude", "codex", "grok", "mistral"]
        )
        XCTAssertEqual(shown([]), [])
    }

    func testTheWindowRowsFollowTheCountAfterTheAdminOrganisationIsLeftOut() {
        let six = shown(["claude", "anthropic-admin", "codex", "antigravity", "grok", "mistral"])
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: six.count), 1, "five listed get one window each")
        let four = shown(["claude", "anthropic-admin", "codex", "grok"])
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: four.count), 2, "four listed keep two")
    }

    // MARK: - Corpora

    private static let lineEndsCorpus: [(String, String, String?)] = [
        ("lone CR between lines", "A=1\rMISTRAL_API_KEY=k1\rB=2\r", "k1"),
        ("CRLF then LF then CR", "A=1\r\nMISTRAL_API_KEY=k2\nB=2\r", "k2"),
        ("CR LF CR CR LF", "\r\n\r\r\nMISTRAL_API_KEY=k3\r\r\n", "k3"),
        ("LF CR pair", "MISTRAL_API_KEY=k4\n\rB=2\n\r", "k4"),
        ("no trailing newline", "MISTRAL_API_KEY=k5", "k5"),
        ("no trailing newline after a comment", "MISTRAL_API_KEY=k6 # c", "k6"),
        ("trailing lone CR", "MISTRAL_API_KEY=k7\r", "k7"),
        ("blank and comment lines around", "\n\n# c\n   \n\t# d\nMISTRAL_API_KEY=k8\n# e\n\n", "k8"),
        ("a BOM later in the file hides that line's name", "A=1\n\u{FEFF}MISTRAL_API_KEY=k9\n", nil),
        ("a BOM before the value is part of the value", "MISTRAL_API_KEY=\u{FEFF}k10\n", "\u{FEFF}k10"),
        ("line separator U+2028 is not a line end", "MISTRAL_API_KEY=k11\u{2028}B=2\n", "k11\u{2028}B=2"),
        ("NEL U+0085 is not a line end", "MISTRAL_API_KEY=k12\u{85}\nB=2\n", "k12"),
        ("VT and FF do not end the line", "MISTRAL_API_KEY=k13\u{B}x\n", nil),
    ]

    private static let exportsCorpus: [(String, String, String?)] = [
        ("export with a no-break space", "export\u{A0}MISTRAL_API_KEY=e1\n", "e1"),
        ("export with a file separator", "export\u{1C}MISTRAL_API_KEY=e2\n", "e2"),
        ("export then a line end makes export the name", "export\nMISTRAL_API_KEY=e3\n", "e3"),
        ("export alone then the key on the next line", "export\r\nMISTRAL_API_KEY=e4\r\n", "e4"),
        ("export twice", "export export MISTRAL_API_KEY=e5\n", nil),
        ("export with a quoted name", "export 'MISTRAL_API_KEY'=e6\n", "e6"),
        ("exported name glued", "exportMISTRAL_API_KEY=e7\n", nil),
        ("export with the equals", "export=MISTRAL_API_KEY\nMISTRAL_API_KEY=e8\n", "e8"),
        ("Export capitalised", "Export MISTRAL_API_KEY=e9\n", nil),
    ]

    private static let namesCorpus: [(String, String, String?)] = [
        ("a quoted name", "'MISTRAL_API_KEY'=n1\n", "n1"),
        ("a double quoted name keeps its quotes", "\"MISTRAL_API_KEY\"=n2\nMISTRAL_API_KEY=n2b\n", "n2b"),
        ("a quoted name with a blank after it", "'MISTRAL_API_KEY' \t = n3\n", "n3"),
        ("a quoted name followed by junk", "'MISTRAL_API_KEY'x=n4\nMISTRAL_API_KEY=n4b\n", "n4b"),
        ("an empty quoted name", "''=n5\nMISTRAL_API_KEY=n5b\n", "n5b"),
        ("a quoted name across lines", "'MISTRAL_API_KEY\nx'=n6\nMISTRAL_API_KEY=n6b\n", "n6b"),
        ("an unclosed quoted name swallows nothing but its line", "'MISTRAL_API_KEY=n7\nMISTRAL_API_KEY=n7b\n", "n7b"),
        ("two quoted names make one spanning name", "'a'MISTRAL_API_KEY'b'=n8\nMISTRAL_API_KEY=n8b\n", "n8b"),
        ("name with a trailing hash", "MISTRAL_API_KEY#=n9\n", nil),
        ("name then a hash comment", "MISTRAL_API_KEY #=n10\nMISTRAL_API_KEY=n10b\n", "n10b"),
        ("lowercase name", "mistral_api_key=n11\n", nil),
        ("name with a combining mark", "MISTRAL_API_KEY\u{301}=n12\n", nil),
        ("name with a trailing no-break space then equals", "MISTRAL_API_KEY\u{A0}=n13\n", "n13"),
        ("name then a vertical tab then equals", "MISTRAL_API_KEY\u{B}=n14\n", "n14"),
        ("name then equals on the next line", "MISTRAL_API_KEY\n=n15\nMISTRAL_API_KEY=n15b\n", "n15b"),
        ("equals before the name", "=MISTRAL_API_KEY=n16\nMISTRAL_API_KEY=n16b\n", "n16b"),
        ("a statement made of the name twice", "MISTRAL_API_KEY MISTRAL_API_KEY=n17\nMISTRAL_API_KEY=n17b\n", "n17b"),
        ("the name alone is None and the earlier value does not survive", "MISTRAL_API_KEY=n18\nMISTRAL_API_KEY\n", nil),
        ("the name alone and then a value again", "MISTRAL_API_KEY\nMISTRAL_API_KEY=n19\n", "n19"),
        ("the name alone with a comment", "MISTRAL_API_KEY=n20\nMISTRAL_API_KEY # c\n", nil),
        ("an empty value later than a full one", "MISTRAL_API_KEY=n21\nMISTRAL_API_KEY=\n", nil),
        ("an empty quoted value later than a full one", "MISTRAL_API_KEY=n22\nMISTRAL_API_KEY=''\n", nil),
        ("a blank value later than a full one", "MISTRAL_API_KEY=n23\nMISTRAL_API_KEY=   \n", nil),
        ("a comment value later than a full one", "MISTRAL_API_KEY=n24\nMISTRAL_API_KEY= # c\n", "# c"),
        ("a name glued to a hash after a good key assigns None", "MISTRAL_API_KEY=n27\nMISTRAL_API_KEY#c\n", nil),
        ("an exported name glued to a hash after a good key", "MISTRAL_API_KEY=n28\nexport MISTRAL_API_KEY#c\n", nil),
        ("a name then a tab and a comment after a good key", "MISTRAL_API_KEY=n29\nMISTRAL_API_KEY\t# c\n", nil),
        ("the last of three wins", "MISTRAL_API_KEY=n25a\nMISTRAL_API_KEY=n25b\nMISTRAL_API_KEY=n25c\n", "n25c"),
        ("the last of three when the middle is unparsable", "MISTRAL_API_KEY=n26a\nMISTRAL_API_KEY=\"n26b\nMISTRAL_API_KEY=n26c\n", "n26c"),
    ]

    private static let hashesCorpus: [(String, String, String?)] = [
        ("hash glued to the value", "MISTRAL_API_KEY=h1#c\n", "h1#c"),
        ("blank hash", "MISTRAL_API_KEY=h2 #c\n", "h2"),
        ("tab hash", "MISTRAL_API_KEY=h3\t#c\n", "h3"),
        ("no-break space hash", "MISTRAL_API_KEY=h4\u{A0}#c\n", "h4"),
        ("vertical tab hash", "MISTRAL_API_KEY=h5\u{B}#c\n", "h5"),
        ("many blanks then hash", "MISTRAL_API_KEY=h6   \t  # c # d\n", "h6"),
        ("hash right after equals", "MISTRAL_API_KEY=#h7\n", "#h7"),
        ("blank then hash right after equals", "MISTRAL_API_KEY= #h8\n", "#h8"),
        ("value hash value", "MISTRAL_API_KEY=h9#h9b c#d\n", "h9#h9b c#d"),
        ("a hash inside a double quoted value", "MISTRAL_API_KEY=\"h10 # not a comment\"\n", "h10 # not a comment"),
        ("a hash inside a single quoted value then a comment", "MISTRAL_API_KEY='h11#x' # c\n", "h11#x"),
        ("a hash after the closing quote glued", "MISTRAL_API_KEY=\"h12\"#c\n", "h12"),
        ("a hash after the closing quote with text after the hash", "MISTRAL_API_KEY='h13'  # c 'd'\n", "h13"),
        ("hash line before", "#MISTRAL_API_KEY=h14\n", nil),
        ("hash line before then the key", "#MISTRAL_API_KEY=x\nMISTRAL_API_KEY=h15\n", "h15"),
        ("indented hash line", " \t #MISTRAL_API_KEY=x\nMISTRAL_API_KEY=h16\n", "h16"),
        ("hash and then equals", "# =\nMISTRAL_API_KEY=h17\n", "h17"),
        ("hash value is a bare hash", "MISTRAL_API_KEY=#\n", "#"),
        ("two spaces then hash in the middle of a key-like value", "MISTRAL_API_KEY=sk  #  x\n", "sk"),
    ]

    private static let equalsCorpus: [(String, String, String?)] = [
        ("two equals", "MISTRAL_API_KEY==q1\n", "=q1"),
        ("three equals alone", "MISTRAL_API_KEY===\n", "=="),
        ("equals inside the value", "MISTRAL_API_KEY=a=b=c\n", "a=b=c"),
        ("base64 padding", "MISTRAL_API_KEY=abcd==\n", "abcd=="),
        ("blank equals blank equals", "MISTRAL_API_KEY = = q2\n", "= q2"),
        ("equals then quote", "MISTRAL_API_KEY==\"q3\"\n", "=\"q3\""),
        ("equals blank then quote", "MISTRAL_API_KEY= \"q4\"\n", "q4"),
        ("equals tab quote", "MISTRAL_API_KEY=\t'q5'\n", "q5"),
        ("equals no-break space then value", "MISTRAL_API_KEY=\u{A0}q6\n", "q6"),
        ("equals then line end then value", "MISTRAL_API_KEY=\nq7\n", nil),
    ]

    private static let quotesCorpus: [(String, String, String?)] = [
        ("quote inside an unquoted value", "MISTRAL_API_KEY=ab\"cd\n", "ab\"cd"),
        ("single quote inside an unquoted value", "MISTRAL_API_KEY=ab'cd\n", "ab'cd"),
        ("a quote after the first character", "MISTRAL_API_KEY=a\"b\"\n", "a\"b\""),
        ("double quoted with an inner single quote", "MISTRAL_API_KEY=\"a'b\"\n", "a'b"),
        ("single quoted with an inner double quote", "MISTRAL_API_KEY='a\"b'\n", "a\"b"),
        ("a double quoted value then another quoted value", "MISTRAL_API_KEY=\"a\"\"b\"\n", nil),
        ("a quoted value then a single quoted value", "MISTRAL_API_KEY=\"a\" 'b'\n", nil),
        ("double quoted empty then text", "MISTRAL_API_KEY=\"\"x\n", nil),
        ("double quoted empty alone", "MISTRAL_API_KEY=\"\"\n", nil),
        ("double quoted blanks only", "MISTRAL_API_KEY=\"   \"\n", nil),
        ("a lone double quote", "MISTRAL_API_KEY=\"\n", nil),
        ("a lone single quote at the very end", "MISTRAL_API_KEY='", nil),
        ("a lone double quote at the very end after a good one", "MISTRAL_API_KEY=ok\nMISTRAL_API_KEY=\"", "ok"),
        ("blanks inside quotes are trimmed at the end only", "MISTRAL_API_KEY=\"  q1  \"\n", "q1"),
        ("tab inside quotes at the edges", "MISTRAL_API_KEY=\"\tq2\t\"\n", "q2"),
        ("tab inside the value", "MISTRAL_API_KEY=\"q\t3\"\n", nil),
        ("single quote closes at the first quote", "MISTRAL_API_KEY='a'b'c'\n", nil),
        ("double quote closes at the first quote", "MISTRAL_API_KEY=\"a\"b\"c\"\n", nil),
        ("single quote unterminated, the next line is good", "MISTRAL_API_KEY='a\nMISTRAL_API_KEY=q4\n", "q4"),
        ("double quote unterminated, a later line holds a quote", "MISTRAL_API_KEY=\"a\nB=\"x\"\nMISTRAL_API_KEY=q5\n", "q5"),
        ("a quote opened on another line closes on the key's line", "B=\"x\nMISTRAL_API_KEY=q6\"\n", nil),
        ("a quote opened above swallows the key line whole", "B='x\nMISTRAL_API_KEY=q7\n'\nMISTRAL_API_KEY=q7b\n", "q7b"),
        ("three unbalanced quotes", "B=\"x\nC=\"y\nMISTRAL_API_KEY=\"q8\"\n", "q8"),
        ("single quotes inside a double quoted span", "B=\"it's\nMISTRAL_API_KEY='q9'\n\"\n", nil),
        ("nested other quote kind does not close", "MISTRAL_API_KEY=\"a'\nb\"\n", nil),
        ("quote kind swap after unterminated", "MISTRAL_API_KEY='a\"\nMISTRAL_API_KEY=\"q10\"\n", "q10"),
    ]

    private static let escapesCorpus: [(String, String, String?)] = [
        ("escaped double quote at the start", "MISTRAL_API_KEY=\"\\\"q1\"\n", "\"q1"),
        ("escaped double quote at the end", "MISTRAL_API_KEY=\"q2\\\"\"\n", "q2\""),
        ("two escaped quotes", "MISTRAL_API_KEY=\"a\\\"b\\\"c\"\n", "a\"b\"c"),
        ("escaped backslash then closing quote", "MISTRAL_API_KEY=\"q3\\\\\"\n", "q3\\"),
        ("escaped backslash then quote then more", "MISTRAL_API_KEY=\"a\\\\\"b\"\n", "a\\\"b"),
        ("triple backslash quote", "MISTRAL_API_KEY=\"a\\\\\\\"b\"\n", "a\\\"b"),
        ("single quoted: escaped quote", "MISTRAL_API_KEY='q4\\'x'\n", "q4'x"),
        ("single quoted: backslash n stays", "MISTRAL_API_KEY='q5\\nx'\n", "q5\\nx"),
        ("single quoted: double backslash", "MISTRAL_API_KEY='q6\\\\x'\n", "q6\\x"),
        ("single quoted: backslash before closing", "MISTRAL_API_KEY='q7\\\\'\n", "q7\\"),
        ("single quoted: escaped double quote is no escape", "MISTRAL_API_KEY='q8\\\"x'\n", "q8\\\"x"),
        ("double quoted: backslash t decodes to a tab", "MISTRAL_API_KEY=\"q9\\tx\"\n", nil),
        ("double quoted: backslash t at the edge is trimmed", "MISTRAL_API_KEY=\"\\tq10\\t\"\n", "q10"),
        ("double quoted: backslash a is BEL", "MISTRAL_API_KEY=\"q11\\ax\"\n", nil),
        ("double quoted: backslash b is BS", "MISTRAL_API_KEY=\"q12\\bx\"\n", nil),
        ("double quoted: backslash f", "MISTRAL_API_KEY=\"q13\\fx\"\n", nil),
        ("double quoted: backslash v", "MISTRAL_API_KEY=\"q14\\vx\"\n", nil),
        ("double quoted: backslash r", "MISTRAL_API_KEY=\"q15\\rx\"\n", nil),
        ("double quoted: backslash n at the end is trimmed", "MISTRAL_API_KEY=\"q16\\n\"\n", "q16"),
        ("double quoted: backslash n at the start is trimmed", "MISTRAL_API_KEY=\"\\nq17\"\n", "q17"),
        ("double quoted: backslash apostrophe", "MISTRAL_API_KEY=\"q18\\'x\"\n", "q18'x"),
        ("double quoted: unknown escapes stay", "MISTRAL_API_KEY=\"q19\\x41\\u0041\\101\\0\\ \\.\"\n", "q19\\x41\\u0041\\101\\0\\ \\."),
        ("double quoted: trailing lone backslash before the close", "MISTRAL_API_KEY=\"q20\\\\\"\n", "q20\\"),
        ("double quoted: backslash at the end of the line then the quote", "MISTRAL_API_KEY=\"q21\\\n\"\n", "q21\\"),
        ("unclosed after escaped quote falls back to the backslash", "MISTRAL_API_KEY=\"q22\\\"\nB=1\n", "q22\\"),
        ("unclosed after two escaped quotes falls back to the last", "MISTRAL_API_KEY=\"q23\\\"x\\\"\nB=1\n", "q23\"x\\"),
        ("unclosed single after two escaped quotes", "MISTRAL_API_KEY='q24\\'x\\'\nB=1\n", "q24'x\\"),
        ("escaped quote followed by a real close later", "MISTRAL_API_KEY=\"q25\\\"x\"\nB=\"y\"\n", "q25\"x"),
        ("escaped quote in an unquoted value", "MISTRAL_API_KEY=q26\\\"x\n", "q26\\\"x"),
        ("backslash at the end of an unquoted value", "MISTRAL_API_KEY=q27\\\n", "q27\\"),
        ("backslash n in an unquoted value stays", "MISTRAL_API_KEY=q28\\nx\n", "q28\\nx"),
        ("escape then unicode", "MISTRAL_API_KEY=\"q29\\\u{E9}\"\n", "q29\\\u{E9}"),
    ]

    private static let unicodeCorpus: [(String, String, String?)] = [
        ("precomposed e acute", "MISTRAL_API_KEY=caf\u{E9}\n", "caf\u{E9}"),
        ("decomposed e acute", "MISTRAL_API_KEY=cafe\u{301}\n", "cafe\u{301}"),
        ("combining mark right after equals", "MISTRAL_API_KEY=\u{301}x\n", "\u{301}x"),
        ("combining mark before the hash blank", "MISTRAL_API_KEY=x\u{301} #c\n", "x\u{301}"),
        ("astral emoji", "MISTRAL_API_KEY=\u{1F600}x\n", "\u{1F600}x"),
        ("astral then hash", "MISTRAL_API_KEY=\u{1F600} # c\n", "\u{1F600}"),
        ("regional indicator flag", "MISTRAL_API_KEY=\u{1F1EB}\u{1F1F7}\n", "\u{1F1EB}\u{1F1F7}"),
        ("zero width joiner family", "MISTRAL_API_KEY=\u{1F468}\u{200D}\u{1F469}\n", "\u{1F468}\u{200D}\u{1F469}"),
        ("thai with combining vowels", "MISTRAL_API_KEY=\u{E01}\u{E33}\u{E01}\u{E33}\n", "\u{E01}\u{E33}\u{E01}\u{E33}"),
        ("hangul jamo", "MISTRAL_API_KEY=\u{1100}\u{1161}\u{11A8}\n", "\u{1100}\u{1161}\u{11A8}"),
        ("astral inside double quotes", "MISTRAL_API_KEY=\"\u{1F600}\"\n", "\u{1F600}"),
        ("astral name char", "\u{1F600}=1\nMISTRAL_API_KEY=u1\n", "u1"),
        ("ideographic space blank", "MISTRAL_API_KEY=\u{3000}u2\u{3000}#c\n", "u2"),
        ("em space blank before hash", "MISTRAL_API_KEY=u3\u{2003}#c\n", "u3"),
        ("mongolian vowel separator is not a blank", "MISTRAL_API_KEY=u4\u{180E}#c\n", "u4\u{180E}#c"),
        ("zero width space edges", "MISTRAL_API_KEY=\u{200B}u5\u{200B}\n", "u5"),
        ("line separator inside a double quoted value", "MISTRAL_API_KEY=\"u6\u{2028}x\"\n", "u6\u{2028}x"),
        ("paragraph separator inside an unquoted value", "MISTRAL_API_KEY=u7\u{2029}x\n", "u7\u{2029}x"),
        ("no-break space inside the value", "MISTRAL_API_KEY=u8\u{A0}x\n", "u8\u{A0}x"),
        ("zero width joiner inside the value", "MISTRAL_API_KEY=u9\u{200D}x\n", "u9\u{200D}x"),
        ("soft hyphen inside the value", "MISTRAL_API_KEY=u10\u{AD}x\n", "u10\u{AD}x"),
        ("bidi mark inside the value", "MISTRAL_API_KEY=u11\u{202E}x\n", "u11\u{202E}x"),
        ("private use inside the value", "MISTRAL_API_KEY=u12\u{E000}x\n", "u12\u{E000}x"),
        ("noncharacter inside the value", "MISTRAL_API_KEY=u13\u{FFFE}x\n", "u13\u{FFFE}x"),
    ]

    private static let controlsCorpus: [(String, String, String?)] = [
        ("NUL inside an unquoted value", "MISTRAL_API_KEY=a\u{0}b\n", nil),
        ("NUL at the end of an unquoted value", "MISTRAL_API_KEY=ab\u{0}\n", nil),
        ("NUL at the start of an unquoted value", "MISTRAL_API_KEY=\u{0}ab\n", nil),
        ("NUL line before a good one", "\u{0}\nMISTRAL_API_KEY=c3\n", "c3"),
        ("DEL inside the value", "MISTRAL_API_KEY=a\u{7F}b\n", nil),
        ("DEL at the end", "MISTRAL_API_KEY=ab\u{7F}\n", nil),
        ("C1 control inside the value", "MISTRAL_API_KEY=a\u{90}b\n", nil),
        ("last C1 control inside the value", "MISTRAL_API_KEY=a\u{9F}b\n", nil),
        ("NEL inside a double quoted value", "MISTRAL_API_KEY=\"a\u{85}b\"\n", nil),
        ("NEL at the edge of a double quoted value is trimmed", "MISTRAL_API_KEY=\"\u{85}ab\u{85}\"\n", "ab"),
        ("ESC at the edge of a value is not trimmed", "MISTRAL_API_KEY=ab\u{1B}\n", nil),
        ("file separator at the edge of an unquoted value", "MISTRAL_API_KEY=ab\u{1C}\n", "ab"),
        ("group separator inside a quoted value", "MISTRAL_API_KEY=\"a\u{1D}b\"\n", nil),
        ("record separator at the start of a quoted value", "MISTRAL_API_KEY=\"\u{1E}ab\"\n", nil),
        ("unit separator after the closing quote", "MISTRAL_API_KEY=\"ab\"\u{1F}\n", "ab"),
        ("tab inside a single quoted value", "MISTRAL_API_KEY='a\tb'\n", nil),
        ("tab inside an unquoted value", "MISTRAL_API_KEY=a\tb\n", nil),
        ("CR inside a double quoted value", "MISTRAL_API_KEY=\"a\rb\"\n", nil),
        ("CRLF inside a single quoted value", "MISTRAL_API_KEY='a\r\nb'\n", nil),
        ("vertical tab inside a quoted value", "MISTRAL_API_KEY=\"a\u{B}b\"\n", nil),
        ("form feed inside a quoted value", "MISTRAL_API_KEY=\"a\u{C}b\"\n", nil),
        ("backslash r inside a double quoted value", "MISTRAL_API_KEY=\"a\\rb\"\n", nil),
        ("backslash v inside a double quoted value", "MISTRAL_API_KEY=\"a\\vb\"\n", nil),
        ("backslash b inside a double quoted value", "MISTRAL_API_KEY=\"a\\bb\"\n", nil),
        ("backslash a inside a double quoted value", "MISTRAL_API_KEY=\"a\\ab\"\n", nil),
        ("backslash f inside a double quoted value", "MISTRAL_API_KEY=\"a\\fb\"\n", nil),
        ("backslash t inside a double quoted value", "MISTRAL_API_KEY=\"a\\tb\"\n", nil),
        ("an earlier good key and a later multiline one", "MISTRAL_API_KEY=good\nMISTRAL_API_KEY=\"a\nb\"\n", nil),
        ("a later multiline one that is None-valued name", "MISTRAL_API_KEY=\"a\nb\"\nMISTRAL_API_KEY=good\n", "good"),
    ]
}
