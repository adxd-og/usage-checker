import SwiftUI

/// Tinted glass capsule badge ("Sign in", "Not running", "Error") with a white label.
struct OMChip: View {
    let text: String
    let tint: Color

    /// Strength of the capsule's glass tint. The label is white and needs a strong,
    /// saturated glass behind it to read as green/orange/red/grey.
    static let glassTintOpacity: Double = 0.85

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, OMSpacing.s)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .liquidGlass(in: Capsule(), tint: tint.opacity(Self.glassTintOpacity))
    }
}

#Preview {
    HStack { OMChip(text: "Sign in", tint: .orange); OMChip(text: "Not running", tint: .secondary); OMChip(text: "Error", tint: .red) }
        .padding()
}
