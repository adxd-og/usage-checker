import SwiftUI

/// The footnote's metrics, from `Dashboard-Overview(-Light).dc.html`.
enum UpdatedFootnoteRules {
    static let dotSize: CGFloat = 7
    static let spacing: CGFloat = 8
    static let fontSize: CGFloat = 11.5
    /// In from the sidebar's content edge.
    static let horizontalPadding: CGFloat = 12
}

/// "Updated 7s ago" with a dot in the poll's colour (`UpdatedCopy`). The age ticks every
/// five seconds, as the popover header's does; only this line redraws on the tick.
struct UpdatedFootnote: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let status = UpdatedCopy.status(of: snapshot)
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let text = UpdatedCopy.text(fetchedAt: snapshot.fetchedAt, now: context.date)
            HStack(spacing: UpdatedFootnoteRules.spacing) {
                Circle()
                    .fill(Self.paint(UpdatedCopy.dot(for: status)))
                    .frame(width: UpdatedFootnoteRules.dotSize, height: UpdatedFootnoteRules.dotSize)
                Text(text)
                    .lineLimit(1)
            }
            .font(.system(size: UpdatedFootnoteRules.fontSize))
            .foregroundStyle(.om(.secondary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(UpdatedCopy.accessibilityLabel(text: text, status: status))
        }
    }

    /// A colour role through the environment's appearance, or the system orange.
    private static func paint(_ dot: UpdatedDot) -> AnyShapeStyle {
        switch dot {
        case .token(let token): return AnyShapeStyle(OMColor(token))
        case .systemOrange: return AnyShapeStyle(Color.orange)
        }
    }
}
