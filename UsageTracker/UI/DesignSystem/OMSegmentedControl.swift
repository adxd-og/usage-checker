import SwiftUI

struct OMSegmentItem: Identifiable, Equatable {
    let id: String
    let title: String
    var serviceID: String? = nil
    var sfFallback: String = "sparkles"
    var showsDot: Bool = false
}

/// Capsule segmented control ("All · Claude · Codex …"). The selected item is a
/// glass capsule inside a GlassGroup, which carries it between items. With more
/// than four items the provider names no longer fit 360 pt, so those segments go
/// icon-only — the name stays in the tooltip and the accessibility label.
/// `alwaysShowsTitles` opts a wider surface out of that, and `keyboardShortcuts`
/// out of ⌘1…⌘9.
struct OMSegmentedControl: View {
    let items: [OMSegmentItem]
    @Binding var selection: String
    /// Popover: names disappear past four items. Dashboard: always show them —
    /// its header is a window wide, and a row of unlabelled logos is a quiz.
    var alwaysShowsTitles: Bool = false
    /// Popover: ⌘1…⌘9. Dashboard: off — the window's number keys belong to the
    /// sidebar, and two owners for ⌘1 is one too many.
    var keyboardShortcuts: Bool = true

    /// Which segment keyboard focus is on. nil unless the user is moving through the
    /// control with Tab (Keyboard navigation on); a click does not set it.
    @FocusState private var focusedItemID: String?

    /// Do the provider names fit? Pure, so both surfaces' answers are testable.
    nonisolated static func showsTitles(count: Int, alwaysShowsTitles: Bool) -> Bool {
        alwaysShowsTitles || count <= 4
    }

    /// What one segment wears. Selection and keyboard focus are separate facts and a
    /// segment can have both, so there are four answers, not two flags the view could
    /// combine wrongly.
    nonisolated static func segmentChrome(isSelected: Bool, isFocused: Bool) -> SegmentChrome {
        switch (isSelected, isFocused) {
        case (false, false): return .plain
        case (false, true): return .focusRing
        case (true, false): return .glass
        case (true, true): return .glassAndRing
        }
    }

    private var showsTitles: Bool {
        Self.showsTitles(count: items.count, alwaysShowsTitles: alwaysShowsTitles)
    }

    var body: some View {
        GlassGroup(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    segment(item, index: index)
                }
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(OMSurface.row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }

    @ViewBuilder
    private func segment(_ item: OMSegmentItem, index: Int) -> some View {
        let isSelected = item.id == selection
        let chrome = Self.segmentChrome(isSelected: isSelected, isFocused: focusedItemID == item.id)
        Button {
            withAnimation(.smooth(duration: 0.2)) { selection = item.id }
        } label: {
            HStack(spacing: 5) {
                if let serviceID = item.serviceID {
                    ProviderIconView(serviceID: serviceID, sfFallback: item.sfFallback, size: 12)
                }
                // "All" has no icon, so it always keeps its word.
                if showsTitles || item.serviceID == nil {
                    Text(item.title)
                        .font(OMFont.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if item.showsDot {
                    Circle().fill(OMAgentColor.needsYou).frame(width: 6, height: 6).offset(x: -2, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The system's ring is a rectangle around a capsule; the ring below replaces it.
        .focusEffectDisabled()
        .focused($focusedItemID, equals: item.id)
        .modifier(SelectedCapsule(isSelected: chrome.showsGlass))
        .overlay {
            if chrome.showsFocusRing {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .modifier(SegmentShortcut(index: index, enabled: keyboardShortcuts))
        .help(item.title)
        .accessibilityLabel("\(item.title) tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What one segment draws: nothing, the keyboard-focus ring, the selected glass
/// capsule, or both. Decided by `OMSegmentedControl.segmentChrome(isSelected:isFocused:)`.
enum SegmentChrome: Equatable, Sendable {
    case plain, focusRing, glass, glassAndRing

    var showsGlass: Bool { self == .glass || self == .glassAndRing }
    var showsFocusRing: Bool { self == .focusRing || self == .glassAndRing }
}

/// Glass capsule behind the selected segment, nothing behind the others.
private struct SelectedCapsule: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if isSelected {
            content.liquidGlass(in: Capsule(style: .continuous))
        } else {
            content
        }
    }
}

/// ⌘1…⌘9 for the first nine segments; further items, and surfaces that opted
/// out, have no shortcut.
private struct SegmentShortcut: ViewModifier {
    let index: Int
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled, index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

#Preview("Segments") {
    struct Host: View {
        @State var selection = "all"
        var body: some View {
            OMSegmentedControl(items: [
                OMSegmentItem(id: "all", title: "All"),
                OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude", showsDot: true),
                OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex"),
                OMSegmentItem(id: "antigravity", title: "Antigravity", serviceID: "antigravity"),
            ], selection: $selection)
            .padding().frame(width: 328)
        }
    }
    return Host()
}
