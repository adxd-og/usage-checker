import SwiftUI

/// Tinted capsule badge ("Sign in", "Not running", "Error"). Glass on macOS 26.
struct OMChip: View {
    let text: String
    let tint: Color

    /// Strength of the capsule's glass tint on macOS 26, where the label is white
    /// and needs a strong, saturated glass behind it to read as green/orange/red/grey.
    static let glassTintOpacity: Double = 0.85

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, OMSpacing.s)
            .padding(.vertical, 3)
            .foregroundStyle(labelColor)
            .liquidGlass(in: Capsule(), tint: glassTint)
    }

    /// macOS 26's tinted glass capsule needs a bright white label to read; macOS 14/15's
    /// untinted material is light in light mode, where white text would vanish, so the
    /// label there stays in the semantic tint colour.
    private var labelColor: Color {
        if #available(macOS 26.0, *) {
            return .white
        } else {
            return tint
        }
    }

    private var glassTint: Color? {
        if #available(macOS 26.0, *) {
            return tint.opacity(Self.glassTintOpacity)
        } else {
            return nil
        }
    }
}

#Preview {
    HStack { OMChip(text: "Sign in", tint: .orange); OMChip(text: "Not running", tint: .secondary); OMChip(text: "Error", tint: .red) }
        .padding()
}
