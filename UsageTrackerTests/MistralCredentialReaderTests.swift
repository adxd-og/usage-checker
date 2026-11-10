import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Credential: the key vibe uses, in vibe's own order — a
/// `MISTRAL_API_KEY=` line in `~/.vibe/.env` first (CRLF and quotes tolerated), then its keychain
/// item (`ai.mistral.vibe` / `MISTRAL_API_KEY`, through `/usr/bin/security`). The keychain read
/// and the file are injected: no test touches the real keychain or home.
final class MistralCredentialReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MistralCredentialReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `env` nil leaves no `.env` at all.
    private func reader(keychain: String?, env: String?) throws -> MistralCredentialReader {
        let url = directory.appendingPathComponent(".env")
        if let env { try env.write(to: url, atomically: true, encoding: .utf8) }
        return MistralCredentialReader(keychain: { keychain }, envFileURL: url)
    }

    func testTheEnvFilesKeyComesBeforeVibesKeychainItemAsInVibe() throws {
        XCTAssertEqual(try reader(keychain: "kc-key", env: "MISTRAL_API_KEY=env-key\n").read(), "env-key")
        XCTAssertEqual(try reader(keychain: nil, env: "MISTRAL_API_KEY=env-key\n").read(), "env-key")
    }

    func testTheKeychainIsNotAskedWhileTheEnvFileHoldsAKey() throws {
        let url = directory.appendingPathComponent(".env")
        try "MISTRAL_API_KEY=env-key\n".write(to: url, atomically: true, encoding: .utf8)
        let asked = AskedFlag()
        let reader = MistralCredentialReader(keychain: { asked.set(); return "kc-key" }, envFileURL: url)
        XCTAssertEqual(reader.read(), "env-key")
        XCTAssertFalse(asked.value)
    }

    func testWithoutAKeyInTheEnvFileVibesKeychainItemIsRead() throws {
        XCTAssertEqual(try reader(keychain: "kc-key", env: nil).read(), "kc-key")
        XCTAssertEqual(try reader(keychain: "kc-key", env: "OTHER=1\nMISTRAL_API_KEY=\n").read(), "kc-key")
    }

    func testWindowsLineEndingsAndDoubleQuotesAreTolerated() throws {
        XCTAssertEqual(
            try reader(keychain: nil, env: "OTHER=1\r\nMISTRAL_API_KEY=\"env-key\"\r\n").read(), "env-key"
        )
    }

    func testSingleQuotesAnExportAndSpacesAroundTheEqualsSignAreTolerated() {
        XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: "export MISTRAL_API_KEY = 'env-key'\n"), "env-key")
        XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: "export\tMISTRAL_API_KEY=env-key\n"), "env-key")
        XCTAssertNil(MistralCredentialReader.key(fromEnvFile: "exportMISTRAL_API_KEY=env-key\n"))
    }

    func testAnUnquotedValueEndsWhereItsCommentStarts() {
        XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: "MISTRAL_API_KEY=env-key # mine\n"), "env-key")
        // vibe reads the file with python-dotenv, where any blank before `#` starts the comment.
        XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: "MISTRAL_API_KEY=env-key\t# mine\n"), "env-key")
        XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: "MISTRAL_API_KEY=env#key\n"), "env#key")
    }

    func testACommentedOutLineOrAnotherKeyIsNotTheKey() {
        XCTAssertNil(MistralCredentialReader.key(fromEnvFile: "# MISTRAL_API_KEY=old\nMISTRAL_API_KEY_OLD=x\n"))
    }

    func testTheLastLineWins() {
        XCTAssertEqual(MistralCredentialReader.key(fromEnvFile: "MISTRAL_API_KEY=a\n\nMISTRAL_API_KEY=b\n"), "b")
    }

    /// An OIDC-only sign-in leaves exactly this: no item, no line.
    func testNoKeyAnywhereIsNoKey() throws {
        XCTAssertNil(try reader(keychain: nil, env: nil).read())
        XCTAssertNil(try reader(keychain: "  \n", env: "MISTRAL_API_KEY=\n").read(), "blank is no key")
    }

    /// Whether the injected keychain closure ran; a class so the `@Sendable` closure can set it.
    private final class AskedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = false
        func set() { lock.lock(); asked = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return asked }
    }

    func testTheSecurityToolsAnswerLosesItsNewline() {
        XCTAssertEqual(MistralCredentialReader.key(fromSecurityOutput: Data("kc-key\n".utf8)), "kc-key")
        XCTAssertNil(MistralCredentialReader.key(fromSecurityOutput: Data()))
    }

    func testVibesItemIsReadByItsServiceAndAccount() {
        XCTAssertEqual(MistralKeychain.service, "ai.mistral.vibe")
        XCTAssertEqual(MistralKeychain.account, "MISTRAL_API_KEY")
        XCTAssertEqual(MistralCredentialReader.envKey, "MISTRAL_API_KEY")
        XCTAssertEqual(
            ClaudeKeychainReader.securityArguments(service: MistralKeychain.service, account: MistralKeychain.account),
            ["find-generic-password", "-s", "ai.mistral.vibe", "-a", "MISTRAL_API_KEY", "-w"]
        )
    }
}
