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

    /// `SettingsStore` rather than an injected flag: the pill is the only thing the
    /// `agentsShowInMenuBar` switch controls, and observing it here keeps
    /// `MenuBarLabel` free of a second reason to re-render.
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        if settings.agentsShowInMenuBar,
           let look = Appearance.make(needsYou: needsYou, working: working, total: total) {
            HStack(spacing: 4) {
                Circle()
                    .fill(look.dot)
                    .frame(width: 6, height: 6)
                Text(look.text)
                    .font(OMFont.menuNumeral)
                    .monospacedDigit()
                    .foregroundStyle(look.textColor)
            }
            .padding(.horizontal, 6)
            .frame(height: 15)
            .background(Capsule(style: .continuous).fill(OMSurface.row))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(look.accessibilityLabel)
        }
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

#Preview("Agents pill") {
    // The dark strip stands in for the menu bar; the pill is drawn on the system
    // material there, so a white canvas would flatter it dishonestly.
    VStack(alignment: .leading, spacing: 10) {
        OMAgentsPill(needsYou: 0, working: 0, total: 3)   // grey "3"
        OMAgentsPill(needsYou: 0, working: 2, total: 4)   // blue "2"
        OMAgentsPill(needsYou: 1, working: 2, total: 4)   // amber "1 needs you"
        OMAgentsPill(needsYou: 0, working: 0, total: 0)   // nothing
    }
    .padding()
    .frame(width: 200, alignment: .leading)
    .background(Color.black.opacity(0.85))
}
