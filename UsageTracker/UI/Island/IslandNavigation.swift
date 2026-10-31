import Foundation

/// Where the island's content is (notch-island spec 2026-10-29 § 3.4; § 3.9 `IslandNavigation`):
/// All, or one provider's page. A pure reducer over the inputs the spec names — an open (with
/// the subject an ear's open is about), a tile, a logo, Back, Esc, a ⌘ digit, the providers on
/// screen changing — giving the next page and what the island does about it. `providers` are
/// the ids on screen in display order (`AppState.snapshot.services`): a provider switched off
/// in Settings is not among them, so the shortcuts count past it.
enum IslandNavigation {
    /// What the content shows.
    enum Page: Hashable, Sendable {
        case all
        /// A provider's page, by service id.
        case provider(String)
    }

    enum Input: Equatable, Sendable {
        /// The island opens. `subject`: the provider an ear's open is about (P6); nil for every
        /// other entry, which starts at home.
        case open(subject: String?)
        /// A provider's tile on All.
        case tile(String)
        /// A provider's logo beside the camera in a page: the sibling switcher.
        case logo(String)
        /// "‹ All", or a two-finger swipe right.
        case back
        case escape
        /// ⌘ and a digit: 0 is All, 1–9 the providers in display order.
        case shortcut(Int)
        /// The providers on screen changed: one switched off, the first poll landed.
        case providersChanged
    }

    /// How the content gets to the new page (§ 3.2, Drill-down).
    enum Move: Equatable, Sendable {
        /// The tile grows into its page.
        case drillFromTile
        /// A page with no tile to grow from (a shortcut; an ear in P6): cross-fade and slide.
        case drillWithoutTile
        /// The page goes back into its tile.
        case back
        /// One page to another (a logo, a shortcut in a page): cross-fade and slide.
        case sibling
        /// At once: an open, or the page's provider went away.
        case cut
    }

    enum Action: Equatable, Sendable {
        /// The page changes, with this move.
        case go(Move)
        /// The island's input, nothing to change: already there, or a ⌘ digit with no provider
        /// behind it (swallowed silently, owner 2026-10-30).
        case stay
        /// Esc at All, or at the only provider's page: the island closes.
        case close
        /// Not the island's: Back at All (a swipe there does nothing). A key never passes.
        case pass
    }

    struct Outcome: Equatable, Sendable {
        let page: Page
        let action: Action
    }

    /// Where an open lands without a subject, and where the content falls back to: All, or with
    /// one provider its page (§ 3.4: its page is home). With none, All, which shows the loading
    /// or nothing-on body.
    static func home(providers: [String]) -> Page {
        ProviderGridRules.providerPageIsHome(count: providers.count) ? .provider(providers[0]) : .all
    }

    /// Whether an open lands at home (§ 3.4, every open starts at All): an open from closed or a
    /// move to another display does; one that turns around a close still running on the same
    /// display does not — that is an interrupted close, the content never left, and it keeps its
    /// page (plan ruling R4; Codex review finding 1 rejected).
    static func opensAtHome(route: IslandTransition.OpenRoute) -> Bool {
        route != .reverse
    }

    /// What an open tells the navigation: nil for an interrupted close, or an ear on the island's own
    /// display (the controller passes `.reverse`), with nothing to go to: it keeps its page. An ear's
    /// subject always applies, and a card asked for needs home, since a provider's page may not have
    /// it (§ 3.6; P6 plan R17).
    static func openInput(route: IslandTransition.OpenRoute, subject: String?, reveal: PetCard?) -> Input? {
        if subject == nil, reveal == nil, !opensAtHome(route: route) { return nil }
        return .open(subject: subject)
    }

    /// A provider page with siblings: "‹ All" and the logos show, and Esc, Back and ⌘0 go to All.
    static func isDrilledIn(_ page: Page, providers: [String]) -> Bool {
        guard case .provider(let id) = page else { return false }
        return providers.count > 1 && providers.contains(id)
    }

    /// The page as the providers on screen allow it: the only provider's page when there is one,
    /// All when the page's provider has gone.
    static func resolved(_ page: Page, providers: [String]) -> Page {
        if ProviderGridRules.providerPageIsHome(count: providers.count) { return .provider(providers[0]) }
        if case .provider(let id) = page, !providers.contains(id) { return .all }
        return page
    }

    static func reduce(_ page: Page, _ input: Input, providers: [String]) -> Outcome {
        switch input {
        case .open(let subject):
            let target = subject.flatMap { providers.contains($0) ? Page.provider($0) : nil }
                ?? home(providers: providers)
            return outcome(from: page, to: target, by: .cut)
        case .tile(let id):
            guard page == .all, providers.count > 1, providers.contains(id) else {
                return Outcome(page: page, action: .stay)
            }
            return Outcome(page: .provider(id), action: .go(.drillFromTile))
        case .logo(let id):
            guard isDrilledIn(page, providers: providers), providers.contains(id) else {
                return Outcome(page: page, action: .stay)
            }
            return outcome(from: page, to: .provider(id), by: .sibling)
        case .back:
            return isDrilledIn(page, providers: providers)
                ? Outcome(page: .all, action: .go(.back))
                : Outcome(page: page, action: .pass)
        case .escape:
            return isDrilledIn(page, providers: providers)
                ? Outcome(page: .all, action: .go(.back))
                : Outcome(page: page, action: .close)
        case .shortcut(let digit):
            return shortcut(digit, from: page, providers: providers)
        case .providersChanged:
            return outcome(from: page, to: resolved(page, providers: providers), by: .cut)
        }
    }

    /// ⌘0 is All; ⌘1–⌘9 the providers in display order, from All without a tile to grow from
    /// (§ 3.2), from a page to its sibling. With one provider there is no All to go to, and a
    /// digit may have no provider behind it: either moves nothing and stays the island's, so it
    /// is swallowed without a beep (owner 2026-10-30).
    private static func shortcut(_ digit: Int, from page: Page, providers: [String]) -> Outcome {
        if digit == 0 {
            guard providers.count > 1 else { return Outcome(page: page, action: .stay) }
            return isDrilledIn(page, providers: providers)
                ? Outcome(page: .all, action: .go(.back))
                : Outcome(page: page, action: .stay)
        }
        guard (1...9).contains(digit), digit <= providers.count else { return Outcome(page: page, action: .stay) }
        let target = Page.provider(providers[digit - 1])
        return outcome(from: page, to: target, by: page == .all ? .drillWithoutTile : .sibling)
    }

    private static func outcome(from page: Page, to target: Page, by move: Move) -> Outcome {
        Outcome(page: target, action: page == target ? .stay : .go(move))
    }
}
