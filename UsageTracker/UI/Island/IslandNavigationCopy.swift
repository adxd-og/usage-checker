/// The words of the island's navigation (notch-island spec 2026-10-29 § 3.4, § 3.8): "‹ All" and
/// the provider logos beside the camera, and what VoiceOver hears on a tile. Pure.
enum IslandNavigationCopy {
    /// "‹ All": the word after the chevron.
    static let backTitle = "All"
    /// What VoiceOver says for "‹ All".
    static let backAccessibilityLabel = "Back to all providers"
    /// Its tooltip, with its shortcut.
    static let backHelp = "All providers (⌘0)"
    /// A tile's hint: what a click on it does.
    static let tileHint = "Opens details"
    /// The needs-you dot, said, after a tile's or a logo's reading.
    static let waitingPhrase = "an agent needs you"

    /// A logo's tooltip: its provider and, for the first nine, its shortcut: "Claude (⌘1)".
    static func logoHelp(name: String, position: Int) -> String {
        (1...9).contains(position) ? "\(name) (⌘\(position))" : name
    }

    /// A logo for VoiceOver: the provider, and the waiting agent while one waits.
    static func logoAccessibilityLabel(name: String, waiting: Bool) -> String {
        waiting ? "\(name), \(waitingPhrase)" : name
    }
}
