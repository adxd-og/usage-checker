import SwiftUI

/// One finished agent session in the dashboard's history list. The live counterpart
/// is `OMAgentRow`; this one is deliberately quieter — nothing here is still moving,
/// so there is no state dot, no pulse and no ticking clock.
struct OMAgentHistoryRow: View {
    let record: AgentSessionRecord

    /// Rendered through the machine's own clock format: "14:20" is the wrong answer
    /// on a Mac that shows 2:20 PM everywhere else (same rule as `InsightsView`).
    private var startedAt: String {
        record.startedAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: OMSpacing.s + 1) {
            ProviderIconView(
                serviceID: record.source.rawValue,
                sfFallback: Self.sfFallback(record.source),
                size: 18
            )
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)

            Text(record.project)
                .font(OMFont.bodyStrong)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: OMSpacing.s)

            if let approvals = Self.approvalsText(record.needsYouCount) {
                Text(approvals)
                    .font(OMFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(OMAgentColor.needsYou)
                    .help("Waited for you \(record.needsYouCount) time\(record.needsYouCount == 1 ? "" : "s")")
            }
            Text(Self.turnsText(record.turns))
                .font(OMFont.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
            Text(AgentHistorySummary.duration(record.endedAt.timeIntervalSince(record.startedAt)))
                .font(OMFont.numeral)
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
            Text(startedAt)
                .font(OMFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: OMRadius.row, style: .continuous).fill(OMSurface.row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: record, startedAt: startedAt))
    }

    nonisolated static func turnsText(_ turns: Int) -> String {
        "\(turns) turn\(turns == 1 ? "" : "s")"
    }

    /// nil at zero: a marker that is always there stops meaning anything.
    nonisolated static func approvalsText(_ count: Int) -> String? {
        count > 0 ? "⚠︎ \(count)" : nil
    }

    /// VoiceOver reads the glyphs and the columns as one sentence.
    nonisolated static func accessibilityLabel(for record: AgentSessionRecord, startedAt: String) -> String {
        var parts = [
            record.project,
            AgentRowText.sourceName(record.source),
            "started \(startedAt)",
            "ran \(AgentHistorySummary.duration(record.endedAt.timeIntervalSince(record.startedAt)))",
            turnsText(record.turns)
        ]
        if record.needsYouCount > 0 {
            parts.append("\(record.needsYouCount) approval\(record.needsYouCount == 1 ? "" : "s") waited")
        }
        return parts.joined(separator: ", ")
    }

    /// Both sources ship a bundled logo; these only matter to a stripped catalog.
    nonisolated private static func sfFallback(_ source: AgentSource) -> String {
        switch source {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }
}

#if DEBUG
@MainActor
private func historyRowPreviewStack() -> some View {
    func record(_ project: String, source: AgentSource, minutes: Double, turns: Int, needsYou: Int) -> AgentSessionRecord {
        let ended = Date(timeIntervalSince1970: 1_788_341_400)
        return AgentSessionRecord(
            id: "\(source.rawValue):\(project)", source: source, project: project,
            startedAt: ended.addingTimeInterval(-minutes * 60), endedAt: ended,
            turns: turns, needsYouCount: needsYou
        )
    }
    return VStack(spacing: 5) {
        OMAgentHistoryRow(record: record("Usage tracker", source: .claude, minutes: 192, turns: 14, needsYou: 2))
        OMAgentHistoryRow(record: record("Orion Gate / mobile-app", source: .claude, minutes: 45, turns: 1, needsYou: 0))
        OMAgentHistoryRow(record: record("orion-gemini", source: .codex, minutes: 0.5, turns: 3, needsYou: 0))
    }
    .padding()
    .frame(width: 560)
}

#Preview("History rows — light") { historyRowPreviewStack() }
#Preview("History rows — dark") { historyRowPreviewStack().preferredColorScheme(.dark) }
#endif
