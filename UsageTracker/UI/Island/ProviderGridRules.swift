import CoreGraphics

/// The island's grid (notch-island spec 2026-10-29 § 3.3, § 3.9 `ProviderGridRules`): the
/// columns every row splits, where each provider tile and the cost tile go for each
/// provider count, and the decisions the popover's views used to make on their own. Pure.
enum ProviderGridRules {
    /// One place in a row of tiles.
    enum Slot: Equatable, Sendable {
        /// A provider's tile, by service id.
        case provider(String)
        /// The cost tile, in the slot an odd provider count leaves.
        case cost
        /// Nothing: an odd count with no dollars to show.
        case empty
    }

    /// The tile rows of the grid.
    struct Grid: Equatable, Sendable {
        /// Rows of two slots; empty when there is no grid (one provider, whose page is
        /// home, or none).
        let tileRows: [[Slot]]
        /// The cost tile sits over keep awake in the lower row's right half: an even count
        /// with dollars to show.
        let costInLowerRow: Bool
    }

    /// The widths every row splits, for one island width.
    struct Columns: Equatable, Sendable {
        /// Inside the island's padding.
        let content: CGFloat
        /// Right of the habitat: the grid's own width.
        let right: CGFloat
        /// One of the grid's two equal columns.
        let half: CGFloat
        /// Inside a card's padding in one half: where keep awake lays out its controls.
        var cardInterior: CGFloat { half - 2 * ProviderGridRules.cardPadding }
    }

    // MARK: - Tokens (§ 3.3)

    static let padding: CGFloat = 14
    /// Between tiles, cards and rows.
    static let gap: CGFloat = 10
    /// The habitat's column (§ 3.3) and the gap after it (prototype v9).
    static let habitatWidth: CGFloat = 150
    static let habitatGap: CGFloat = 12
    static let cardPadding: CGFloat = 14
    /// Above and below the agents card's heading and list, inside its card.
    static let agentsCardVerticalPadding: CGFloat = 8

    // MARK: - Columns and slots

    /// Right of the habitat when it is there, the content's width when it is not.
    static func columns(bodyWidth: CGFloat, showsHabitat: Bool) -> Columns {
        let content = bodyWidth - 2 * padding
        let right = showsHabitat ? content - habitatWidth - habitatGap : content
        return Columns(content: content, right: right, half: (right - gap) / 2)
    }

    /// One provider: its page is home and there is no grid (§ 3.3, § 3.4).
    static func providerPageIsHome(count: Int) -> Bool {
        count == 1
    }

    /// The cost tile is drawn only when the week has dollars.
    static func showsCostTile(_ services: [ServiceSnapshot]) -> Bool {
        OMCostTile.total(services) > 0
    }

    /// Two tiles a row in the providers' order. An odd count's last row has an orphan
    /// slot: the cost tile takes it (three and five alike), else it stays empty; an even
    /// count puts the cost tile over keep awake in the lower row.
    static func grid(serviceIDs: [String], showsCostTile: Bool) -> Grid {
        guard serviceIDs.count > 1 else { return Grid(tileRows: [], costInLowerRow: false) }
        var rows = stride(from: 0, to: serviceIDs.count, by: 2).map { start -> [Slot] in
            serviceIDs[start..<min(start + 2, serviceIDs.count)].map { Slot.provider($0) }
        }
        let odd = serviceIDs.count % 2 == 1
        if odd {
            rows[rows.count - 1].append(showsCostTile ? .cost : .empty)
        }
        return Grid(tileRows: rows, costInLowerRow: showsCostTile && !odd)
    }

    // MARK: - The bar-label column

    /// The narrowest a tile's bar may get beside the shared label and its figure.
    static let minimumBarTrack: CGFloat = 56

    /// The bar-label column every tile in the grid shares (§ 3.3), so every bar starts at
    /// the same x: the widest label in whole points, never so wide that a tile's bar
    /// shrinks under `minimumBarTrack` beside its figure (a longer label truncates at its
    /// tail). 0 when no tile draws a bar. The view measures the labels.
    static func barLabelWidth(labelWidths: [CGFloat], tileInterior: CGFloat) -> CGFloat {
        guard let widest = labelWidths.max() else { return 0 }
        let room = tileInterior - OMProviderTile.barValueWidth - 2 * OMProviderTile.barGap - minimumBarTrack
        return max(0, min(widest.rounded(.up), room.rounded(.down)))
    }

    // MARK: - Decisions moved out of views (§ 3.3)

    /// A provider carries the needs-you dot while one of its own sessions waits for the
    /// user. Providers without an agent integration (Antigravity, Grok) never do.
    static func showsWaitingDot(serviceID: String, sessions: [AgentSession]) -> Bool {
        guard let source = AgentSource(rawValue: serviceID) else { return false }
        return sessions.contains { $0.source == source && $0.state == .needsYou }
    }

    /// A provider page's weekly-limits card (§ 3.3, decisions moved out of views).
    struct WeeklyRows: Equatable, Sendable {
        /// The rows, in order: windows in use and every `.weekly` window, then the
        /// untouched ones when unfolded or when only one is untouched; never the hero.
        let shown: [UsageBucket]
        /// Untouched model-specific windows (`PopoverView.foldsWhenUnused`).
        let unusedCount: Int
        /// "N unused windows" folds them only when there are two or more: a toggle row
        /// costs as much as the row it hides.
        var showsToggle: Bool { unusedCount > 1 }
    }

    /// Untouched model-specific windows are noise most of the day, so two or more fold
    /// behind a disclosure row; a weekly window keeps its row even at zero.
    static func weeklyRows(for service: ServiceSnapshot, hero: UsageBucket?, showsUnused: Bool) -> WeeklyRows {
        let weekly = service.buckets.filter { $0.kind == .weekly || $0.kind == .modelSpecific }
        let visible = weekly.filter { !PopoverView.foldsWhenUnused($0) }
        let unused = weekly.filter { PopoverView.foldsWhenUnused($0) }
        let unfolded = showsUnused || unused.count == 1 ? unused : []
        return WeeklyRows(shown: (visible + unfolded).filter { $0.id != hero?.id }, unusedCount: unused.count)
    }

    /// The API-equivalent line under a provider page's dollars: once, only when the week
    /// has dollars, never for a pay-as-you-go account.
    static func spendCaption(for service: ServiceSnapshot) -> String? {
        guard (service.weekCost ?? 0) > 0 else { return nil }
        return CostCopy.apiEquivalentCaption(isPayAsYouGo: CostCopy.isPayAsYouGo(service))
    }
}
