import SwiftUI

/// One provider's logo beside the camera in a page (notch-island spec 2026-10-29 § 3.4): the
/// sibling switcher. The page shown stands on the segmented control's raised pill; a provider
/// whose session waits wears the needs-you dot, as a segment did; the pointer lights it as it
/// lights a segment. VoiceOver hears the provider and a waiting agent; the tooltip names the
/// shortcut.
struct IslandLogoButton: View {
    let service: ServiceSnapshot
    let selected: Bool
    let waiting: Bool
    /// The provider's place in display order, from 1: its shortcut.
    let position: Int
    let action: () -> Void

    /// A logo's circle and the glyph in it (the prototype's 26 pt buttons).
    nonisolated static let size: CGFloat = 26
    nonisolated static let glyph: CGFloat = 16
    /// Between two logos.
    nonisolated static let spacing: CGFloat = 6

    var body: some View {
        Button(action: action) {
            ProviderIconView(serviceID: service.id, sfFallback: service.icon, size: Self.glyph)
                .overlay(alignment: .topTrailing) {
                    if waiting {
                        Circle()
                            .fill(.om(OMSegmentedControl.needsYouDotToken))
                            .frame(
                                width: OMSegmentedControl.needsYouDotDiameter,
                                height: OMSegmentedControl.needsYouDotDiameter
                            )
                            .offset(OMSegmentedControl.needsYouDotOffset)
                    }
                }
                .foregroundStyle(.om(OMSegmentedControl.labelToken(isSelected: selected)))
                .frame(width: Self.size, height: Self.size)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(OMSegmentButtonStyle(isSelected: selected))
        .background {
            if selected {
                Color.clear.omGlass(OMSegmentedControl.selectedSurface, in: Capsule(style: .continuous))
            }
        }
        .help(IslandNavigationCopy.logoHelp(name: service.displayName, position: position))
        .accessibilityLabel(IslandNavigationCopy.logoAccessibilityLabel(name: service.displayName, waiting: waiting))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
