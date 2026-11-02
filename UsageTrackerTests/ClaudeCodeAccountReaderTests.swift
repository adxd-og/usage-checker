import XCTest
@testable import Omelette

/// The reader of Claude Code's state file `~/.claude.json`: only `oauthAccount`'s plan name and
/// rate-limit tier, nil for a file that is missing, broken or signed out, and parsed again only
/// when the file's modification date or size moved, or a link to it points elsewhere. The
/// fixture keeps the real file's shape (this Mac's `oauthAccount` keys, ids and names scrubbed)
/// next to a large `projects` object.
final class ClaudeCodeAccountReaderTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent(".claude.json") }
    private let firstWrite = Date(timeIntervalSince1970: 1_793_000_000)
    private let secondWrite = Date(timeIntervalSince1970: 1_793_000_060)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeAccountReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func oauthAccount(plan: String) -> String {
        """
        {"accountUuid":"00000000-0000-4000-8000-000000000001","emailAddress":"user@example.com",
         "organizationUuid":"00000000-0000-4000-8000-000000000002","hasExtraUsageEnabled":false,
         "billingType":"stripe_subscription","accountCreatedAt":"2025-03-01T10:00:00.000Z",
         "subscriptionCreatedAt":"2026-01-15T09:30:00.000Z","ccOnboardingFlags":{},
         "claudeCodeTrialEndsAt":null,"claudeCodeTrialDurationDays":null,"seatTier":null,
         "displayName":"user","fullName":"User","profileFetchedAt":1793000000000,
         "organizationRole":"admin","workspaceRole":null,"organizationName":"User's Organization",
         "organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x",
         "userRateLimitTier":null,"planDisplayName":"\(plan)"}
        """
    }

    /// Two thousand projects ahead of `oauthAccount`, as the real file has them.
    private var projects: String {
        let entries = (0..<2000).map { index in
            #""~/code/project-\#(index)":{"allowedTools":[],"history":[{"display":"run the tests","pastedContents":{}}],"#
                + #""mcpServers":{},"hasTrustDialogAccepted":true,"lastCost":0.42,"lastSessionId":"s-\#(index)"}"#
        }
        return "{" + entries.joined(separator: ",") + "}"
    }

    private func stateFile(plan: String) -> String {
        #"{"numStartups":412,"installMethod":"native","autoUpdates":true,"#
            + #""cachedGrowthBookFeatures":{"tengu_example":true},"projects":\#(projects),"#
            + #""oauthAccount":\#(oauthAccount(plan: plan))}"#
    }

    private func write(_ text: String, to url: URL? = nil, modified: Date) throws {
        let url = url ?? fileURL
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testTheRealFilesShapeDecodesToThePlanNameAndTier() async throws {
        try write(stateFile(plan: "Ultra"), modified: firstWrite)

        let account = await ClaudeCodeAccountReader(fileURL: fileURL).account()

        XCTAssertEqual(
            account,
            ClaudeCodeAccount(planDisplayName: "Ultra", organizationRateLimitTier: "default_claude_max_20x")
        )
    }

    func testAMissingFileReadsAsNoAccount() async {
        let account = await ClaudeCodeAccountReader(fileURL: fileURL).account()
        XCTAssertNil(account)
    }

    func testAFileThatIsNotJSONReadsAsNoAccount() async throws {
        try write(#"{"numStartups":412,"oauthAccount":{"planDisplayName":"Ul"#, modified: firstWrite)

        let account = await ClaudeCodeAccountReader(fileURL: fileURL).account()

        XCTAssertNil(account)
    }

    func testASignedOutFileReadsAsNoAccount() async throws {
        // Claude Code drops `oauthAccount` on a sign-out and keeps everything else.
        try write(#"{"numStartups":412,"projects":\#(projects)}"#, modified: firstWrite)

        let account = await ClaudeCodeAccountReader(fileURL: fileURL).account()

        XCTAssertNil(account)
    }

    func testAnUntouchedFileIsAnsweredFromMemory() async throws {
        let reader = ClaudeCodeAccountReader(fileURL: fileURL)
        try write(stateFile(plan: "Ultra"), modified: firstWrite)
        let first = await reader.account()

        // The same size and the same modification date: what the reader sees of an untouched
        // file. The stale name surviving proves the file was not parsed again.
        try write(stateFile(plan: "Elite"), modified: firstWrite)
        let second = await reader.account()

        XCTAssertEqual(first?.planDisplayName, "Ultra")
        XCTAssertEqual(second?.planDisplayName, "Ultra")
    }

    func testARewriteWithANewModificationDateIsReadAgain() async throws {
        let reader = ClaudeCodeAccountReader(fileURL: fileURL)
        try write(stateFile(plan: "Ultra"), modified: firstWrite)
        _ = await reader.account()

        try write(stateFile(plan: "Elite"), modified: secondWrite)
        let account = await reader.account()

        XCTAssertEqual(account?.planDisplayName, "Elite")
    }

    func testARewriteOfAnotherSizeIsReadAgainUnderTheSameModificationDate() async throws {
        let reader = ClaudeCodeAccountReader(fileURL: fileURL)
        try write(stateFile(plan: "Ultra"), modified: firstWrite)
        _ = await reader.account()

        try write(stateFile(plan: "Max"), modified: firstWrite)
        let account = await reader.account()

        XCTAssertEqual(account?.planDisplayName, "Max")
    }

    func testALinkPointedAtAnotherFileOfTheSameDateAndSizeIsReadAgain() async throws {
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        try write(stateFile(plan: "Ultra"), to: first, modified: firstWrite)
        try write(stateFile(plan: "Elite"), to: second, modified: firstWrite)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: first)
        let reader = ClaudeCodeAccountReader(fileURL: fileURL)
        _ = await reader.account()

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: second)
        let account = await reader.account()

        XCTAssertEqual(account?.planDisplayName, "Elite")
    }
}
