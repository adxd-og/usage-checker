import XCTest
@testable import Omelette

/// The timeline: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab,
/// item 4 ("one bar per bin, stacked by the five largest projects, 'Other' and Outside,
/// coloured by the existing series tokens; hover shows the bin's time and split"), in the
/// mockup's colours, axis and tooltip ("Tue 14:00–14:30", "+1 %", "Movie app 0.7").
/// Project names come from the provider's decoder, which these tests replace with a lookup.
/// A card is built again whenever its share is, even under the same query.
final class LimitsTimelineTests: XCTestCase {
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private func at(_ text: String) -> Date { Self.iso.date(from: text) ?? .distantPast }

    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    /// The mockup's week: from Monday 12 October 10:00 UTC to Friday noon.
    private var week: LimitWindow { LimitWindow(start: at("2026-10-12T10:00:00Z"), end: at("2026-10-16T12:00:00Z")) }

    /// A share with these bins, as the rule hands it over.
    private func share(_ chats: [ChatShare], bins: [LimitBinShare], window: LimitWindow? = nil) -> LimitShare {
        LimitShare(
            window: window ?? week,
            percent: bins.reduce(0) { $0 + $1.delta },
            chats: chats,
            projects: LimitShareRules.projectShares(chats),
            outside: bins.reduce(0) { $0 + $1.outside },
            bins: bins,
            cost: chats.reduce(0) { $0 + $1.cost },
            tokens: 0,
            price: nil,
            costByModel: [:],
            unbinnedOutside: 0,
            earlier: nil
        )
    }

    private func chat(_ id: String, project: String, points: Double) -> ChatShare {
        Fixture.chatShare(id: id, project: project, points: points, cost: points * 60, lastAt: week.end)
    }

    /// Stands in for the provider's decoder: the slug upper-cased, no disk.
    private func named(_ providerID: String, _ slug: String) -> String { slug.uppercased() }

    func testABarStacksTheFiveLargestProjectsThenOtherThenOutside() throws {
        let chats = (1...7).map { chat("c\($0)", project: "p\($0)", points: Double(8 - $0)) }
        let bin = LimitBinShare(
            start: week.start, delta: 8,
            chats: Dictionary(uniqueKeysWithValues: (1...7).map { ("c\($0)", 1.0) }),
            outside: 1
        )
        let timeline = LimitsRules.timeline(of: share(chats, bins: [bin]), serviceID: "claude", projectName: named)
        XCTAssertEqual(timeline.series.map(\.id), ["p1", "p2", "p3", "p4", "p5", "other", "outside"])
        XCTAssertEqual(timeline.series.map(\.name), ["P1", "P2", "P3", "P4", "P5", "Other", "Outside this Mac"])
        XCTAssertEqual(
            timeline.series.map(\.token),
            [.seriesAllModels, .seriesPerModel, .seriesCredits, .seriesSession, .tokenOutput, .muted, .seriesQuota]
        )
        let bar = try XCTUnwrap(timeline.bars.first)
        XCTAssertEqual(bar.parts.map(\.seriesID), ["p1", "p2", "p3", "p4", "p5", "other", "outside"])
        XCTAssertEqual(bar.parts.map(\.base), [0, 1, 2, 3, 4, 5, 7])
        XCTAssertEqual(bar.parts.map(\.points), [1, 1, 1, 1, 1, 2, 1], "the sixth and seventh projects are Other")
        XCTAssertEqual(bar.total, 8, accuracy: 1e-9)
    }

    func testAChatsPointsGoToItsProject() throws {
        let chats = [chat("c1", project: "p1", points: 3), chat("c2", project: "p1", points: 1)]
        let bin = LimitBinShare(start: week.start, delta: 0.75, chats: ["c1": 0.5, "c2": 0.25], outside: 0)
        let timeline = LimitsRules.timeline(of: share(chats, bins: [bin]), serviceID: "claude", projectName: named)
        XCTAssertEqual(timeline.series.map(\.id), ["p1"], "no Other and no Outside in this window")
        let bar = try XCTUnwrap(timeline.bars.first)
        XCTAssertEqual(bar.parts.map(\.seriesID), ["p1"])
        XCTAssertEqual(bar.parts.first?.points ?? -1, 0.75, accuracy: 1e-9)
    }

    func testAHalfHourThatMovedNothingDrawsNoBar() {
        let chats = [chat("c1", project: "p1", points: 1)]
        let bins = [
            LimitBinShare(start: week.start, delta: 0, chats: [:], outside: 0),
            LimitBinShare(start: week.start.addingTimeInterval(1_800), delta: 1, chats: ["c1": 1], outside: 0),
        ]
        let timeline = LimitsRules.timeline(of: share(chats, bins: bins), serviceID: "claude", projectName: named)
        XCTAssertEqual(timeline.bars.map(\.start), [week.start.addingTimeInterval(1_800)])
    }

    func testTheLastBarEndsWithTheWindow() {
        let short = LimitWindow(start: week.start, end: week.start.addingTimeInterval(45 * 60))
        let chats = [chat("c1", project: "p1", points: 2)]
        let bins = [
            LimitBinShare(start: short.start, delta: 1, chats: ["c1": 1], outside: 0),
            LimitBinShare(start: short.start.addingTimeInterval(1_800), delta: 1, chats: ["c1": 1], outside: 0),
        ]
        let timeline = LimitsRules.timeline(
            of: share(chats, bins: bins, window: short), serviceID: "claude", projectName: named
        )
        guard timeline.bars.count == 2 else { return XCTFail("expected two bars, got \(timeline.bars.count)") }
        XCTAssertEqual(timeline.bars.map(\.end), [short.start.addingTimeInterval(1_800), short.end])
        XCTAssertEqual(LimitsRules.barInset(timeline.bars[0]), 270, accuracy: 1e-9, "a bar takes 70 % of its half hour")
    }

    func testTheAxisRisesInWholePointsToTheTallestBar() {
        XCTAssertEqual(LimitsRules.timelineAxis(top: 2.6), [0, 1, 2, 3])
        XCTAssertEqual(LimitsRules.timelineAxis(top: 3), [0, 1, 2, 3])
        XCTAssertEqual(LimitsRules.timelineAxis(top: 0.4), [0, 1])
        XCTAssertEqual(LimitsRules.timelineAxis(top: 0), [0, 1], "an empty window still has an axis")
        XCTAssertEqual(LimitsRules.timelineAxis(top: 7), [0, 2, 4, 6, 8], "never more than four steps")
    }

    func testTheTooltipNamesTheHalfHourAndItsSplit() throws {
        let movie = "-Users-tester-Projects-movie"
        let fleet = "-Users-tester-Projects-fleet"
        let chats = [chat("c1", project: movie, points: 7), chat("c2", project: fleet, points: 3)]
        let bin = LimitBinShare(start: at("2026-10-13T14:00:00Z"), delta: 1, chats: ["c1": 0.7, "c2": 0.3], outside: 0)
        let names = [movie: "Movie app", fleet: "omelette / fleet"]
        let timeline = LimitsRules.timeline(
            of: share(chats, bins: [bin]), serviceID: "claude", projectName: { _, slug in names[slug] ?? slug }
        )
        let bar = try XCTUnwrap(timeline.bars.first)
        XCTAssertEqual(
            LimitsRules.timelineTooltip(
                for: bar, in: timeline, now: at("2026-10-16T12:00:00Z"), calendar: calendar, locale: locale
            ),
            HistoryTooltip(title: "Tue 14:00–14:30", headline: "+1 %", rows: [
                HistoryTooltipRow(label: "Movie app", value: "0.7", token: .seriesAllModels),
                HistoryTooltipRow(label: "omelette / fleet", value: "0.3", token: .seriesPerModel),
            ])
        )
    }

    func testTheAxisMarksHoursForASessionDaysForAWeekAndFiveDaysForAMonth() {
        XCTAssertEqual(LimitsRules.timelineStride(span: .session), HistoryAxisStride(component: .hour, count: 1))
        XCTAssertEqual(LimitsRules.timelineStride(span: .week), HistoryAxisStride(component: .day, count: 1))
        XCTAssertEqual(LimitsRules.timelineStride(span: .month), HistoryAxisStride(component: .day, count: 5))
        let monday = at("2026-10-12T14:00:00Z")
        XCTAssertEqual(LimitsCopy.timelineAxisDate(monday, span: .session, calendar: calendar, locale: locale), "14:00")
        XCTAssertEqual(LimitsCopy.timelineAxisDate(monday, span: .week, calendar: calendar, locale: locale), "Mon 12 Oct")
        XCTAssertEqual(LimitsCopy.timelineAxisDate(monday, span: .month, calendar: calendar, locale: locale), "12 Oct")
    }

    func testTheCardSaysTimelineInThirtyMinuteStepsAndPointsReadAsTheMockupWritesThem() {
        XCTAssertEqual(LimitsCopy.timelineTitle, "Timeline")
        XCTAssertEqual(LimitsCopy.timelineCaption, "30-minute steps")
        XCTAssertEqual(LimitsCopy.otherProjects, "Other")
        XCTAssertEqual(LimitsCopy.timelineAxisLabel(3), "3 %")
        XCTAssertEqual(LimitsCopy.binRise(2), "+2 %")
        XCTAssertEqual(LimitsCopy.binRise(1.4), "+1.4 %")
        XCTAssertEqual(LimitsCopy.binPoints(0.7), "0.7")
    }

    func testACardIsBuiltAgainForAShareCutAgainUnderTheSameQuery() {
        // The window open now, cut again after an ingest: a new half hour moved, the query
        // (provider, window, period, measure) is the same.
        let chats = [chat("c1", project: "p1", points: 2)]
        let before = Fixture.limitLoad(share: share(chats, bins: [
            LimitBinShare(start: week.start, delta: 2, chats: ["c1": 2], outside: 0),
        ]))
        let recut = Fixture.limitLoad(share: share(chats, bins: [
            LimitBinShare(start: week.start, delta: 2, chats: ["c1": 2], outside: 0),
            LimitBinShare(start: week.start.addingTimeInterval(1_800), delta: 1, chats: [:], outside: 1),
        ]))
        XCTAssertEqual(before.query, recut.query)
        XCTAssertNotEqual(before.cardKey, recut.cardKey)
        XCTAssertEqual(before.cardKey, Fixture.limitLoad(share: before.share).cardKey)
    }
}
