import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.3 (Grid rules) and § 3.9
/// (`ProviderGridRules`), written from the spec and the plan's rulings R3, R10 without
/// looking at the executor's tests first: the slots for 1...5 providers at every island
/// width, the bar-label column's boundaries and the minimum bar track, the waiting dot per
/// source and state, the weekly rows and their fold, the spend caption.
final class ProviderGridRulesVerificationTests: XCTestCase {
    private let ids = ["claude", "codex", "antigravity", "grok", "anthropic-admin"]

    // MARK: - Columns at every width, with and without the habitat

    func testEveryRowSplitsTwoEqualColumnsAtEveryIslandWidthWithAndWithoutTheHabitat() {
        let widths: [CGFloat] = [560, 640, 720]
        for body in widths {
            for habitat in [true, false] {
                let columns = ProviderGridRules.columns(bodyWidth: body, showsHabitat: habitat)
                let label = "\(body) habitat \(habitat)"
                XCTAssertEqual(columns.content, body - 28, label)
                XCTAssertEqual(2 * columns.half + ProviderGridRules.gap, columns.right, "\(label): two equal halves and one gap")
                if habitat {
                    XCTAssertEqual(columns.right + ProviderGridRules.habitatWidth + ProviderGridRules.habitatGap, columns.content, label)
                } else {
                    XCTAssertEqual(columns.right, columns.content, label)
                }
                XCTAssertEqual(columns.cardInterior, columns.half - 28, "\(label): a card's padding is 14 a side")
            }
        }
    }

    func testTheSpecsHalvesAt720WithoutTheHabitatAndAt560() {
        XCTAssertEqual(ProviderGridRules.columns(bodyWidth: 720, showsHabitat: false).half, 341)
        XCTAssertEqual(ProviderGridRules.columns(bodyWidth: 560, showsHabitat: false).half, 261)
        // A 560 body with a habitat is not reachable (D12), but the rule must stay finite.
        XCTAssertEqual(ProviderGridRules.columns(bodyWidth: 560, showsHabitat: true).half, 180)
    }

    // MARK: - Slots for 1...5 providers

    func testTheGridInvariantsHoldForEveryCountWithAndWithoutDollars() {
        for count in 0...5 {
            for dollars in [true, false] {
                let given = Array(ids.prefix(count))
                let grid = ProviderGridRules.grid(serviceIDs: given, showsCostTile: dollars)
                let label = "\(count) providers, dollars \(dollars)"
                let slots = grid.tileRows.flatMap { $0 }
                XCTAssertTrue(grid.tileRows.allSatisfy { $0.count == 2 }, "\(label): every row has two slots")
                let providers: [String] = slots.compactMap { if case .provider(let id) = $0 { id } else { nil } }
                XCTAssertEqual(providers, count > 1 ? given : [], "\(label): providers in order, once")
                let costSlots = slots.filter { $0 == .cost }.count
                XCTAssertLessThanOrEqual(costSlots + (grid.costInLowerRow ? 1 : 0), 1, "\(label): the cost tile is drawn once")
                if !dollars {
                    XCTAssertEqual(costSlots, 0, label)
                    XCTAssertFalse(grid.costInLowerRow, label)
                }
                if count > 1, dollars {
                    XCTAssertEqual(costSlots + (grid.costInLowerRow ? 1 : 0), 1, "\(label): with dollars it is drawn")
                    XCTAssertEqual(grid.costInLowerRow, count % 2 == 0, "\(label): lower row only for an even count")
                }
                if count > 1, count % 2 == 1 {
                    XCTAssertEqual(slots.last, dollars ? .cost : .empty, "\(label): the orphan slot is the last one")
                }
                if count <= 1 {
                    XCTAssertEqual(grid, .init(tileRows: [], costInLowerRow: false), label)
                }
            }
        }
    }

    func testTwoProvidersWithoutDollarsLeaveTheLowerRowsOtherHalfToKeepAwake() {
        XCTAssertEqual(
            ProviderGridRules.grid(serviceIDs: ["claude", "codex"], showsCostTile: false),
            .init(tileRows: [[.provider("claude"), .provider("codex")]], costInLowerRow: false)
        )
    }

    func testTheCostTileNeedsDollarsAnywhereInTheSnapshotNotInEveryProvider() {
        let some = [Fixture.snapshot(id: "claude", weekCost: nil), Fixture.snapshot(id: "grok", weekCost: 0.01)]
        XCTAssertTrue(ProviderGridRules.showsCostTile(some), "one provider's cent is a week with dollars")
        XCTAssertFalse(ProviderGridRules.showsCostTile([Fixture.snapshot(id: "claude", weekCost: 0)]), "$0 shows no tile")
        XCTAssertFalse(ProviderGridRules.showsCostTile([
            Fixture.snapshot(id: "claude", weekCost: 0), Fixture.snapshot(id: "codex", weekCost: 0),
        ]))
    }

    // MARK: - The bar-label column

    func testTheLabelColumnTakesTheWidestLabelOnWholePointsUpToTheRoomTheBarLeaves() {
        // Interior 196: 196 − 36 − 2 × 8 − 56 = 88 of room.
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [88], tileInterior: 196), 88, "exactly the room")
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [88.2], tileInterior: 196), 88, "a hair over: cut back")
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [87.2], tileInterior: 196), 88, "rounded up, still fits")
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [87.0], tileInterior: 196), 87)
    }

    func testAFractionalTileInteriorNeverGivesTheLabelMoreThanItsWholePointsOfRoom() {
        // Room 88.6: a 89 pt label would leave the bar 55.6 pt.
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [120], tileInterior: 196.6), 88)
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [120], tileInterior: 196.99), 88)
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [120], tileInterior: 197), 89)
    }

    func testTheWidestOfSeveralLabelsDecidesNotTheLast() {
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [39.24, 28.76, 30.09], tileInterior: 196), 40)
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [28.76, 39.24], tileInterior: 196), 40)
    }

    func testTheBarAlwaysKeepsItsMinimumTrackAndTheColumnIsAsWideAsThatAllows() {
        let value = OMProviderTile.barValueWidth, gap = OMProviderTile.barGap
        for interior in stride(from: 0 as CGFloat, through: 320, by: 0.25) {
            for widest in [0, 0.4, 28.76, 39.24, 88, 105.5, 200] as [CGFloat] {
                let width = ProviderGridRules.barLabelWidth(labelWidths: [widest], tileInterior: interior)
                let label = "interior \(interior), widest \(widest)"
                XCTAssertGreaterThanOrEqual(width, 0, label)
                XCTAssertEqual(width, width.rounded(), label)
                XCTAssertLessThanOrEqual(width, widest.rounded(.up), label)
                if width > 0 {
                    XCTAssertGreaterThanOrEqual(interior - width - value - 2 * gap, ProviderGridRules.minimumBarTrack, label)
                }
                // Maximal: one more point would either pass the label or crush the bar.
                if width < widest.rounded(.up) {
                    XCTAssertLessThan(interior - (width + 1) - value - 2 * gap, ProviderGridRules.minimumBarTrack, label)
                }
            }
        }
    }

    func testZeroWidthLabelsAreAColumnOfZeroNotNoColumn() {
        XCTAssertEqual(ProviderGridRules.barLabelWidth(labelWidths: [0, 0], tileInterior: 196), 0)
    }

    // MARK: - The waiting dot

    func testOnlyANeedsYouSessionOfTheProvidersOwnSourceLightsItsDot() {
        for source in [AgentSource.claude, .codex] {
            for state in AgentState.allCases {
                let sessions = [Fixture.agentSession(sessionID: "s", source: source, state: state)]
                XCTAssertEqual(
                    ProviderGridRules.showsWaitingDot(serviceID: source.rawValue, sessions: sessions),
                    state == .needsYou, "\(source) \(state)"
                )
                let other: AgentSource = source == .claude ? .codex : .claude
                XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: other.rawValue, sessions: sessions), "\(source) \(state) is not \(other)'s")
            }
        }
    }

    func testOneWaitingSessionAmongManyLightsTheDotAndAServiceIDNobodyKnowsNever() {
        let sessions = [
            Fixture.agentSession(sessionID: "a", source: .claude, state: .working),
            Fixture.agentSession(sessionID: "b", source: .claude, state: .done),
            Fixture.agentSession(sessionID: "c", source: .claude, state: .needsYou),
        ]
        XCTAssertTrue(ProviderGridRules.showsWaitingDot(serviceID: "claude", sessions: sessions))
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "anthropic-admin", sessions: sessions))
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "", sessions: sessions))
    }

    // MARK: - Weekly rows

    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 34, kind: .session)
    private let week = Fixture.bucket(id: "seven_day", label: "All models", percent: 76, kind: .weekly)

    private func model(_ id: String, _ percent: Double) -> UsageBucket {
        Fixture.bucket(id: id, label: id, percent: percent, kind: .modelSpecific)
    }

    private func rows(_ buckets: [UsageBucket], unfolded: Bool = false) -> ProviderGridRules.WeeklyRows {
        let service = Fixture.snapshot(id: "claude", buckets: buckets)
        return ProviderGridRules.weeklyRows(for: service, hero: WindowRanking.detailHero(for: service), showsUnused: unfolded)
    }

    func testTheFoldTakesOnlyUntouchedModelWindowsAndTheThresholdIsAFiftiethOfAPercent() {
        let result = rows([session, week, model("m_used", 0.05), model("m_dust", 0.049), model("m_zero", 0)])
        XCTAssertEqual(result.shown.map(\.id), ["seven_day", "m_used"], "0.05 % is in use; 0.049 % is untouched")
        XCTAssertEqual(result.unusedCount, 2)
        XCTAssertTrue(result.showsToggle)
    }

    func testFoldedAndUnfoldedDifferByExactlyTheUnusedCountWhenTwoOrMoreFold() {
        for unused in 2...4 {
            let buckets = [session, week, model("m_used", 20)] + (0..<unused).map { model("m_idle\($0)", 0) }
            let folded = rows(buckets).shown.count
            let unfolded = rows(buckets, unfolded: true).shown.count
            XCTAssertEqual(unfolded - folded, unused, "the toggle's \(unused) is what it reveals")
            XCTAssertEqual(rows(buckets).unusedCount, unused)
        }
    }

    func testOneUntouchedWindowIsInlineWhetherOrNotTheFoldIsOpenAndHasNoToggle() {
        let buckets = [session, week, model("m_idle", 0)]
        XCTAssertEqual(rows(buckets).shown, rows(buckets, unfolded: true).shown)
        XCTAssertEqual(rows(buckets).shown.map(\.id), ["seven_day", "m_idle"])
        XCTAssertFalse(rows(buckets).showsToggle)
    }

    func testUnfoldedUntouchedWindowsKeepTheirOrderAfterTheRowsInUse() {
        let buckets = [session, week, model("m_idle1", 0), model("m_used", 30), model("m_idle2", 0)]
        XCTAssertEqual(rows(buckets, unfolded: true).shown.map(\.id), ["seven_day", "m_used", "m_idle1", "m_idle2"])
    }

    func testAnotherWeeklyWindowKeepsItsRowEvenAtZeroAndOnlyTheHeroIsDropped() {
        // No session: the more constrained weekly is the hero; the other weekly stays.
        let pro = Fixture.bucket(id: "weekly_pro", label: "Pro", percent: 80, kind: .weekly)
        let flash = Fixture.bucket(id: "weekly_flash", label: "Flash", percent: 0, kind: .weekly)
        let service = Fixture.snapshot(id: "antigravity", buckets: [pro, flash])
        let hero = WindowRanking.detailHero(for: service)
        let result = ProviderGridRules.weeklyRows(for: service, hero: hero, showsUnused: false)
        XCTAssertEqual(hero?.id, "weekly_pro")
        XCTAssertEqual(result.shown.map(\.id), ["weekly_flash"])
        XCTAssertEqual(result.unusedCount, 0, "a weekly window never folds")
    }

    func testWithoutAHeroEveryWeeklyRowShowsAndAnEmptyServiceHasNoRows() {
        let service = Fixture.snapshot(id: "claude", buckets: [week, model("m_used", 10)])
        let result = ProviderGridRules.weeklyRows(for: service, hero: nil, showsUnused: false)
        XCTAssertEqual(result.shown.map(\.id), ["seven_day", "m_used"])
        let empty = ProviderGridRules.weeklyRows(for: Fixture.snapshot(id: "claude"), hero: nil, showsUnused: true)
        XCTAssertEqual(empty, .init(shown: [], unusedCount: 0))
        XCTAssertFalse(empty.showsToggle)
    }

    func testTheHeroIsNeverARowAtAnyFoldState() {
        for unfolded in [true, false] {
            let service = Fixture.snapshot(id: "claude", buckets: [week, model("m_a", 0), model("m_b", 0)])
            let hero = WindowRanking.detailHero(for: service)
            XCTAssertEqual(hero?.id, "seven_day")
            XCTAssertFalse(ProviderGridRules.weeklyRows(for: service, hero: hero, showsUnused: unfolded).shown.contains { $0.id == hero?.id })
        }
    }

    // MARK: - The spend caption

    func testAPayAsYouGoAccountWithOnlyItsBudgetWindowGetsNoCaption() {
        let budget = Fixture.bucket(id: "claude_weekly_budget", label: "Weekly budget", percent: 10)
        XCTAssertNil(ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", buckets: [budget], weekCost: 12)))
    }

    func testEverySubscriptionStateKeepsTheCaptionOnlyAnAnsweringWindowlessAccountDrops() {
        for state in [ServiceState.notSignedIn, .notRunning, .error] {
            XCTAssertEqual(
                ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", weekCost: 3, state: state)),
                CostCopy.apiEquivalent, "\(state)"
            )
        }
        XCTAssertNil(ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", weekCost: 3, state: .ok)))
    }

    func testTheCaptionIsTheSentenceWithoutDollarsNever() {
        let session = Fixture.bucket(id: "five_hour", percent: 5, kind: .session)
        XCTAssertNil(ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", buckets: [session], weekCost: -1)))
        XCTAssertNotNil(ProviderGridRules.spendCaption(for: Fixture.snapshot(id: "claude", buckets: [session], weekCost: 0.01)))
    }
}
