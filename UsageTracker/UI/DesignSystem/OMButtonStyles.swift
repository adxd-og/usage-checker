import SwiftUI

/// Row buttons (Allow, Deny, Enable) and the footer's.
enum OMButtonSize: Sendable {
    case small, regular
}

/// The popover's buttons (`Main.dc.html`): one filled accent control per surface —
/// Allow — and everything else a capsule or a circle on the same control-track glass
/// the segmented control stands on (liquid-glass spec § Principles 1–2).
enum OMButtonRules {
    static let accentFill: OMColorToken = .accent
    static let accentLabel: OMColorToken = .onAccent
    /// The 1 px top light on the yolk fill (`inset 0 1px 0 rgba(255,255,255,0.45)`).
    static let accentHighlight = OMRGBA.white(0.45)
    static let capsuleSurface: OMGlassKind = .controlTrack
    static let capsuleLabel: OMColorToken = .text
    static let fontSize: CGFloat = 12.5
    static let iconSize: CGFloat = 15
    static let iconSpacing: CGFloat = 7

    static func height(_ size: OMButtonSize) -> CGFloat {
        size == .small ? 28 : 32
    }

    /// Allow 18, Deny 16; the footer's labelled button 12 before its icon.
    static func leadingPadding(_ size: OMButtonSize, accent: Bool) -> CGFloat {
        switch (size, accent) {
        case (_, true): 18
        case (.small, false): 16
        case (.regular, false): 12
        }
    }

    /// Allow 18, Deny 16; the footer's labelled button 14 after its title.
    static func trailingPadding(_ size: OMButtonSize, accent: Bool) -> CGFloat {
        switch (size, accent) {
        case (_, true): 18
        case (.small, false): 16
        case (.regular, false): 14
        }
    }
}

/// Allow: `Button("Allow") { … }.buttonStyle(.omAccent(.small))`.
struct OMAccentButtonStyle: ButtonStyle {
    let size: OMButtonSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: OMButtonRules.fontSize, weight: .semibold))
            .foregroundStyle(.om(OMButtonRules.accentLabel))
            .lineLimit(1)
            .padding(.leading, OMButtonRules.leadingPadding(size, accent: true))
            .padding(.trailing, OMButtonRules.trailingPadding(size, accent: true))
            .frame(height: OMButtonRules.height(size))
            .background {
                Capsule(style: .continuous).fill(.om(OMButtonRules.accentFill))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: OMButtonRules.accentHighlight.color, location: 0),
                                .init(color: OMButtonRules.accentHighlight.withOpacity(0).color, location: 0.5),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Deny, Enable and the footer's Dashboard: `.buttonStyle(.omCapsule(.small))`. A
/// `Label` shows its icon and title 7 pt apart.
struct OMCapsuleButtonStyle: ButtonStyle {
    let size: OMButtonSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(OMButtonLabelStyle())
            .font(.system(size: OMButtonRules.fontSize, weight: .semibold))
            .foregroundStyle(.om(OMButtonRules.capsuleLabel))
            .lineLimit(1)
            .padding(.leading, OMButtonRules.leadingPadding(size, accent: false))
            .padding(.trailing, OMButtonRules.trailingPadding(size, accent: false))
            .frame(height: OMButtonRules.height(size))
            .omGlass(OMButtonRules.capsuleSurface, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The footer's icon buttons: a 32 pt circle on the same glass. The label is a `Label`
/// so VoiceOver reads its title while only the icon shows.
struct OMCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: OMButtonRules.iconSize))
            .foregroundStyle(.om(OMButtonRules.capsuleLabel))
            .frame(width: OMButtonRules.height(.regular), height: OMButtonRules.height(.regular))
            .omGlass(OMButtonRules.capsuleSurface, in: Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct OMButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: OMButtonRules.iconSpacing) {
            configuration.icon
                .font(.system(size: OMButtonRules.iconSize))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == OMAccentButtonStyle {
    static func omAccent(_ size: OMButtonSize) -> OMAccentButtonStyle { OMAccentButtonStyle(size: size) }
}

extension ButtonStyle where Self == OMCapsuleButtonStyle {
    static func omCapsule(_ size: OMButtonSize) -> OMCapsuleButtonStyle { OMCapsuleButtonStyle(size: size) }
}

extension ButtonStyle where Self == OMCircleButtonStyle {
    static var omCircle: OMCircleButtonStyle { OMCircleButtonStyle() }
}

#Preview("Buttons") {
    HStack(spacing: 8) {
        Button("Allow") {}.buttonStyle(.omAccent(.small))
        Button("Deny") {}.buttonStyle(.omCapsule(.small))
        Button {} label: { Label("Dashboard", systemImage: "sidebar.left") }.buttonStyle(.omCapsule(.regular))
        Button {} label: { Label("Settings", systemImage: "slider.horizontal.3") }.buttonStyle(.omCircle)
    }
    .padding()
    .background(OMWindowBackground())
}
