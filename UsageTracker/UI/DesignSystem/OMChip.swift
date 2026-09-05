import SwiftUI

/// Tinted capsule badge ("Sign in", "Not running", "Error"). Glass on macOS 26.
struct OMChip: View {
    let text: String
    let tint: Color

    /// Strength of the capsule's tint relative to the label colour.
    static let glassTintOpacity: Double = 0.22

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, OMSpacing.s)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            // A full-strength glass tint is the same colour as the label, which made
            // "Installed" green-on-green on macOS 26. A washed tint keeps the capsule
            // coloured and the text readable in both themes.
            .liquidGlass(in: Capsule(), tint: tint.opacity(Self.glassTintOpacity))
    }
}

#Preview {
    HStack { OMChip(text: "Sign in", tint: .orange); OMChip(text: "Not running", tint: .secondary); OMChip(text: "Error", tint: .red) }
        .padding()
}
