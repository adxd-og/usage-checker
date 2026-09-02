import SwiftUI

/// Tinted capsule badge ("Sign in", "Not running", "Error"). Glass on macOS 26.
struct OMChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, OMSpacing.s)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .liquidGlass(in: Capsule(), tint: tint)
    }
}

#Preview {
    HStack { OMChip(text: "Sign in", tint: .orange); OMChip(text: "Not running", tint: .secondary); OMChip(text: "Error", tint: .red) }
        .padding()
}
