import SwiftUI

/// Menu-bar capsule for agent sessions: a dot plus a count, amber and spelled out
/// while a session waits for you (approved mockup, option B).
///
/// Deliberately static in every state. The status item's hosting view never leaves
/// the screen, so anything that animates here animates forever — the one pulse in
/// the menu bar (`MiniServiceBar`) enters `TimelineView(.animation)` only while a
/// critical reading is on show, and even that is off under Reduce Motion. The pill
/// has no motion at all, which is why it needs no Reduce Motion branch.
struct OMAgentsPill: View {
    let needsYou: Int
    let working: Int
    let total: Int

    var body: some View {
        EmptyView()   // Task 2 draws the capsule.
    }
}

extension OMAgentsPill {
    /// The pill's entire appearance as data, so the selection rule is testable
    /// without a view hierarchy.
    struct Appearance: Equatable {
        let dot: Color
        let textColor: Color
        let text: String
        let accessibilityLabel: String

        /// `nil` means "draw nothing".
        ///
        /// Precedence is needs-you → working → quiet, and deliberately not
        /// "whichever count is biggest": one session blocked on an approval
        /// outranks nine that are merely busy.
        static func make(needsYou: Int, working: Int, total: Int) -> Appearance? {
            guard total > 0 else { return nil }
            let label = accessibilityText(needsYou: needsYou, total: total)
            if needsYou > 0 {
                return Appearance(
                    dot: OMAgentColor.needsYou,
                    textColor: OMAgentColor.needsYou,
                    text: "\(needsYou) needs you",
                    accessibilityLabel: label
                )
            }
            if working > 0 {
                return Appearance(
                    dot: OMAgentColor.working,
                    textColor: .primary,
                    text: "\(working)",
                    accessibilityLabel: label
                )
            }
            return Appearance(
                dot: OMAgentColor.idle,
                textColor: .secondary,
                text: "\(total)",
                accessibilityLabel: label
            )
        }

        /// "5 agent sessions, 2 need you". The visible text is a bare number in two
        /// of the three states, so VoiceOver has to say what the number counts.
        static func accessibilityText(needsYou: Int, total: Int) -> String {
            let sessions = total == 1 ? "1 agent session" : "\(total) agent sessions"
            guard needsYou > 0 else { return sessions }
            return "\(sessions), \(needsYou) \(needsYou == 1 ? "needs" : "need") you"
        }
    }
}
