import Foundation

/// Whether a percentage is read as "how much is used" or "how much is left".
///
/// One rule for every ring, bar, number and spoken label in the app, the widget
/// extension and the `omelette` CLI. Nothing else in the codebase writes `100 - x`:
/// a surface that does its own subtraction is a surface that will disagree with the
/// next one by a rounding step.
///
/// Colours, status phrases, thresholds, pace alerts and notifications deliberately
/// do **not** come through here — they stay on the used value. Red has to mean
/// "nearly out" in both modes: a ring showing "5% left" is the same emergency as
/// one showing "95% used", and inverting the colour with the number would turn the
/// alarm green at exactly the wrong moment.
///
/// Compiled into three targets (see `project.yml`), which is why it imports
/// Foundation and nothing else.
enum PercentDisplay {
    enum Mode: String, Codable, Sendable {
        /// The default since 1.0: 0 → 100 as the window fills.
        case used
        /// 100 → 0 as the window fills.
        case remaining
    }

    /// The number to draw, 0…100. `used` is clamped first: a spend limit can report
    /// 137%, and "−37% left" is not a thing to put on a ring.
    static func shown(_ used: Double, mode: Mode) -> Double {
        let clamped = max(0, min(100, used))
        return mode == .remaining ? 100 - clamped : clamped
    }

    /// "37%" / "63%" — the bare number a ring, a bar, a tile or a widget row draws,
    /// where the gauge beside it already says which way it is counting.
    static func percentText(_ used: Double, mode: Mode) -> String {
        "\(Int(shown(used, mode: mode).rounded()))%"
    }

    /// "37" / "63" — the menu bar has room for a 22 pt bar and two digits, and has
    /// never printed the sign.
    static func bareNumber(_ used: Double, mode: Mode) -> String {
        "\(Int(shown(used, mode: mode).rounded()))"
    }

    /// The word that spells the number out.
    static func suffix(mode: Mode) -> String {
        mode == .remaining ? "left" : "used"
    }

    /// "42%" / "58% left" — for text with no gauge next to it: the menu bar tooltip,
    /// `omelette status`, the status line. The word appears in `remaining` only:
    /// "42%" has meant used since 1.0 and every script that greps those lines
    /// expects it, while a bare "58%" would be a lie.
    static func percentPhrase(_ used: Double, mode: Mode) -> String {
        let text = percentText(used, mode: mode)
        return mode == .remaining ? "\(text) \(suffix(mode: mode))" : text
    }

    /// "42 percent used" / "58 percent left". VoiceOver reads words, never glyphs,
    /// so it always gets the suffix.
    static func spoken(_ used: Double, mode: Mode) -> String {
        "\(Int(shown(used, mode: mode).rounded())) percent \(suffix(mode: mode))"
    }

    /// The pace marker's position, 0…1. The dot marks "even pace" so the fill can be
    /// read against it; mirroring it in `remaining` is what keeps that comparison
    /// true — with the fill inverted and the dot left alone, every window would look
    /// behind schedule. nil stays nil: no reset time, no marker.
    static func pace(_ elapsedFraction: Double?, mode: Mode) -> Double? {
        guard let elapsedFraction else { return nil }
        let clamped = max(0, min(1, elapsedFraction))
        return mode == .remaining ? 1 - clamped : clamped
    }
}
