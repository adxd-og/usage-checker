import SwiftUI

/// "WEEKLY LIMITS · resets Thu" — micro uppercase label with an optional caption.
struct OMSectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(OMFont.micro)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, OMSpacing.xs)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview { OMSectionHeader(title: "Weekly limits", trailing: "resets Thu").padding().frame(width: 328) }
