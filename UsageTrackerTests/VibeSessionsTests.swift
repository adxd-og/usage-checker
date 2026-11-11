import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Sessions: each vibe session directory is
/// one chat for History, `status.json` and `get_sessions`, with its title, the folder it ran in,
/// its last activity from the last point, its tokens and cost. A session with no total is not
/// listed. A range clips a chat by day, as Codex's chats are clipped.
final class VibeSessionsTests: XCTestCase {
    private var root: URL!
    /// 2026-11-06 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)
    /// 2026-11-06 00:00 UTC.
    private let nov6 = Date(timeIntervalSince1970: 1_793_923_200)
    /// 7 November 00:00 in Australia/Eucla (6 November 15:15 UTC).
    private let euclaNov7 = Date(timeIntervalSince1970: 1_793_978_100)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    private let eucla: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Eucla")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MistralModelPricing.update([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        MistralModelPricing.update([:])
    }

    private func chats(_ sessions: [VibeFixture.Session], calendar: Calendar, from start: Date) async throws -> [SessionSummary] {
        for session in sessions { try VibeFixture.write(session, under: root) }
        let vibe = VibeUsageAggregator(rootURL: root, ledgerURL: nil, calendar: calendar)
        await vibe.refresh(now: now)
        return await vibe.sessions(from: start, to: now)
    }

    func testEachSessionWithATotalIsOneChatNewestFirst() async throws {
        let list = try await chats(
            [VibeFixture.whole(), VibeFixture.pruned(), VibeFixture.repeated(), VibeFixture.noTotal(), VibeFixture.glm(), VibeFixture.medium()],
            calendar: utc, from: nov6
        )
        // last points: pruned 15:28:27, whole 15:08:56, repeated 15:07:18, medium 14:34:42, glm 14:34:38 (UTC)
        XCTAssertEqual(
            list.map(\.id),
            [VibeFixture.pruned().id, VibeFixture.whole().id, VibeFixture.repeated().id, VibeFixture.medium().id, VibeFixture.glm().id],
            "the session that never called a model is not listed"
        )
        XCTAssertEqual(Set(list.map(\.providerID)), ["mistral"])
    }

    func testAChatCarriesItsTitleFolderSpanTurnsTokensAndDollars() async throws {
        MistralModelPricing.update(ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily))
        let list = try await chats([VibeFixture.whole()], calendar: utc, from: nov6)
        let chat = try XCTUnwrap(list.first)
        XCTAssertEqual(chat.id, VibeFixture.whole().id)
        XCTAssertEqual(chat.title, "Fixture title")
        XCTAssertEqual(chat.projectSlug, "%2Ftmp%2FVibe%20Fixtures%2Fprobe")
        XCTAssertNil(chat.origin)
        XCTAssertEqual(chat.firstAt.timeIntervalSince1970, 1_793_977_712.751, accuracy: 1e-6)
        XCTAssertEqual(chat.lastAt.timeIntervalSince1970, 1_793_977_736.011, accuracy: 1e-6)
        XCTAssertEqual(chat.turns, 6)
        XCTAssertEqual(chat.tokens.input, 17_463)
        XCTAssertEqual(chat.tokens.cacheRead, 45_568)
        XCTAssertEqual(chat.tokens.output, 3_101)
        XCTAssertEqual(chat.tokens.cost?.total ?? 0, 0.021_925_96, accuracy: 1e-9, "12 224.10 + 3 189.76 + 6 512.10 per million")
        XCTAssertEqual(chat.mainTokens, chat.tokens)
        XCTAssertTrue(chat.agents.isEmpty)
        XCTAssertEqual(chat.days.map(\.day), [nov6])
        XCTAssertEqual(chat.days.map(\.turns), [6])
    }

    func testLastActivityIsTheLastPointEvenWhenItAddsNothing() async throws {
        let list = try await chats([VibeFixture.repeated()], calendar: utc, from: nov6)
        let chat = try XCTUnwrap(list.first)
        XCTAssertEqual(chat.firstAt.timeIntervalSince1970, 1_793_977_627.409, accuracy: 1e-6)
        XCTAssertEqual(
            chat.lastAt.timeIntervalSince1970, 1_793_977_638.323, accuracy: 1e-6,
            "the third 6 997, eleven seconds after the only step"
        )
        XCTAssertEqual(chat.turns, 1)
    }

    func testARangeClipsAChatByDayAndItsModelRowStaysWhole() async throws {
        let list = try await chats([VibeFixture.midnight()], calendar: eucla, from: euclaNov7)
        let chat = try XCTUnwrap(list.first)
        XCTAssertEqual(chat.days.map(\.day), [euclaNov7])
        XCTAssertEqual(chat.turns, 2)
        XCTAssertEqual(chat.tokens.total, 6_822_727, "197 790 + 6 624 937")
        XCTAssertEqual(chat.firstAt.timeIntervalSince1970, 1_793_977_614.876, accuracy: 1e-6, "the chat's own span")
        XCTAssertEqual(chat.models.map(\.model), ["glm-5-3"])
        XCTAssertEqual(chat.models.map(\.turns), [4])
        XCTAssertEqual(chat.models.first?.tokens.total, 8_446_352, "1 623 625 + 6 822 727")
        XCTAssertNil(chat.models.first?.effort)
    }

    func testAChatsProjectReadsAsTheFolderItRanIn() async throws {
        var untitled = VibeFixture.whole()
        untitled.title = nil
        let list = try await chats([VibeFixture.pruned(), untitled], calendar: utc, from: nov6)
        let pruned = try XCTUnwrap(list.first { $0.id == VibeFixture.pruned().id })
        XCTAssertEqual(SessionCopy.projectName(providerID: pruned.providerID, projectSlug: pruned.projectSlug), "Vibe Fixtures / movie app")
        XCTAssertEqual(SessionCopy.rowTitle(pruned, calendar: utc, locale: Locale(identifier: "en_US")), "Fixture title")
        let nameless = try XCTUnwrap(list.first { $0.id == untitled.id })
        XCTAssertNil(nameless.title)
        XCTAssertTrue(
            SessionCopy.rowTitle(nameless, calendar: utc, locale: Locale(identifier: "en_US")).hasPrefix("Vibe Fixtures / probe · ")
        )
    }
}
