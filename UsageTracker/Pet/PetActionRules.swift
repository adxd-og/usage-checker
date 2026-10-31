import Foundation

/// A card a pet click brings into view in the island's right column.
enum PetCard: Hashable, Sendable {
    case agents
    case keepAwake
}

/// One thing the island does for a click on the pet (notch-island spec 2026-10-29 § 3.5, D11).
enum PetEffect: Equatable, Sendable {
    /// Bring the waiting session's window forward (`SessionActivator`); the island closes once it
    /// is in front, if no later jump or reopen came first (§ 3.5, Jump from the island).
    case jump(sessionID: String)
    /// Move the island's content (`IslandNavigation`).
    case navigate(IslandNavigation.Input)
    /// Scroll the right column so the card shows, once it is on screen (`revealReady`).
    case reveal(PetCard)
    /// Claude Code's own sign-in in Terminal (`ClaudeSignInModel.signIn`).
    case signIn
    /// The install page in the browser (`ClaudeSignInCopy.installURL`).
    case openInstallPage
    /// Settings on a tab; the island closes as Settings turns key (§ 3.1, Dismissal).
    case openSettings(SettingsTab)
    /// The island closes: the click sends the user to another app it would cover.
    case closeIsland
    /// A heart for 1.2 s (`PetRuntime.pat`): the habitat's own.
    case pat
}

/// What a click on the pet, or VoiceOver's action on the habitat, does in the island (notch-island
/// spec 2026-10-29 § 3.5 "Mood rule", Click; § 3.8; D11): `PetMoodRules`' action as the island's
/// own moves for the page it shows and the providers on screen. Pure.
enum PetActionRules {
    static func effects(of action: PetAction, page: IslandNavigation.Page, providers: [String]) -> [PetEffect] {
        switch action {
        case .jump(let id):
            return [.jump(sessionID: id)]
        case .needsYouList:
            // All's agents card lists every session, the waiting ones first.
            return IslandNavigation.isDrilledIn(page, providers: providers)
                ? [.navigate(.back), .reveal(.agents)]
                : [.reveal(.agents)]
        case .claudeRecovery(let recovery):
            switch recovery {
            case .signIn: return [.closeIsland, .signIn]
            case .install: return [.closeIsland, .openInstallPage]
            case .keychainAccess: return [.openSettings(.advanced)]
            case .noAction: return []
            }
        case .providerPage(let id):
            guard providers.contains(id) else { return [] }
            // Its page already shows: nowhere to go, and a click still answers.
            guard page != .provider(id) else { return [.pat] }
            // From All the tile grows into its page; from a sibling's page, its logo.
            return [.navigate(page == .all ? .tile(id) : .logo(id))]
        case .keepAwakeCard:
            return [.reveal(.keepAwake)]
        case .providersSettings:
            return [.openSettings(.providers)]
        case .pat:
            return [.pat]
        case .nothing:
            return []
        }
    }

    /// The click does something: VoiceOver reads the habitat as a button (§ 3.8). An unreadable
    /// sign-in has nothing to do.
    static func isActionable(_ action: PetAction) -> Bool {
        switch action {
        case .nothing, .claudeRecovery(.noAction): false
        default: true
        }
    }

    /// A card a click asked for can be scrolled to: no page move runs, and the card is on screen —
    /// keep awake is on every page; the agents card only once the lower row shows one (after Back
    /// from Grok's or Antigravity's page, once All has settled). Until then the reveal waits.
    static func revealReady(_ card: PetCard, agentsCardShown: Bool, moving: Bool) -> Bool {
        guard !moving else { return false }
        switch card {
        case .agents: return agentsCardShown
        case .keepAwake: return true
        }
    }

    /// A pending reveal still belongs to where the island is going: the navigation's destination
    /// is the page it was asked on (All after the click's own Back). Any newer move — ⌘1 before
    /// Back settled, a tile, a logo — drops it, so another page's card is never scrolled to
    /// (Codex's re-review of the P5c plan).
    static func revealStillWanted(askedOn: IslandNavigation.Page, destination: IslandNavigation.Page) -> Bool {
        askedOn == destination
    }
}
