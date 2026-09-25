import SwiftUI

/// "Weekly limits      resets Thu 12:59" — a sentence-case title with an optional
/// caption on its baseline (liquid-glass spec § Principles 3: no uppercase micro
/// labels). Titles are passed in sentence case; nothing here changes their case.
struct OMSectionHeader: View {
    let title: String
    var trailing: String? = nil

    nonisolated static let titleSize: CGFloat = 13
    nonisolated static let trailingSize: CGFloat = 11.5
    nonisolated static var titleToken: OMColorToken { .text }
    nonisolated static var trailingToken: OMColorToken { .secondary }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: Self.titleSize, weight: .semibold))
                .foregroundStyle(.om(Self.titleToken))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: Self.trailingSize))
                    .foregroundStyle(.om(Self.trailingToken))
                    .lineLimit(1)
            }
        }
        .padding(.top, OMSpacing.xs)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview { OMSectionHeader(title: "Weekly limits", trailing: "resets in 3d 21h (Thu 12:59)").padding().frame(width: 328) }
