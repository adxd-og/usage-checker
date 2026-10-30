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
}
