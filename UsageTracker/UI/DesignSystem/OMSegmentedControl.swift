import SwiftUI

struct OMSegmentItem: Identifiable, Equatable {
    let id: String
    let title: String
    var serviceID: String? = nil
    var sfFallback: String = "sparkles"
    var showsDot: Bool = false
}

/// The two sizes the 3.0 mockups draw the control at. Built on demand (the weights make
/// it a non-Sendable value, so it is not a stored static).
struct OMSegmentMetrics: Equatable {
    let height: CGFloat
    let fontSize: CGFloat
    let selectedWeight: Font.Weight
    let weight: Font.Weight
    let iconSize: CGFloat
    let iconTitleSpacing: CGFloat
    /// Before a logo. A segment without one uses `trailingPadding` on both sides.
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    /// Every segment an equal share of the width, or each as wide as its label.
    let fillsWidth: Bool

    /// `Main.dc.html`: 30 pt segments sharing the popover's width, 12 pt semibold
    /// titles, 16 pt logos.
    static var popover: OMSegmentMetrics {
        OMSegmentMetrics(height: 30, fontSize: 12, selectedWeight: .semibold, weight: .semibold,
                         iconSize: 16, iconTitleSpacing: 7, leadingPadding: 6, trailingPadding: 6,
                         fillsWidth: true)
    }

    /// `Dashboard-Overview.dc.html`, `Dashboard-Agents.dc.html`: 30 pt segments that hug
    /// their labels, 12.5 pt titles (semibold when selected, medium otherwise), 15 pt logos.
    static var dashboard: OMSegmentMetrics {
        OMSegmentMetrics(height: 30, fontSize: 12.5, selectedWeight: .semibold, weight: .medium,
                         iconSize: 15, iconTitleSpacing: 7, leadingPadding: 10, trailingPadding: 14,
                         fillsWidth: false)
    }
}

/// Capsule segmented control ("All · Claude · Codex …") in the 3.0 look (liquid-glass
/// spec § Components, "Segmented controls"): the track is tinted glass, the selected
/// segment a raised pill on it, the labels read in the text and secondary tokens, and
/// keyboard focus is the yolk focus ring. Sized per surface (`OMSegmentMetrics`). With
/// more than four items the provider names no longer fit 360 pt, so those segments go
/// icon-only — the name stays in the tooltip and the accessibility label.
/// `alwaysShowsTitles` opts a wider surface out of that, and `keyboardShortcuts` out
/// of ⌘1…⌘9.
struct OMSegmentedControl: View {
    let items: [OMSegmentItem]
    @Binding var selection: String
    /// Popover: names disappear past four items. Dashboard: always show them —
    /// its header is a window wide, and a row of unlabelled logos is a quiz.
    let alwaysShowsTitles: Bool
    /// Popover: ⌘1…⌘9. Dashboard: off — the window's number keys belong to the
    /// sidebar, and two owners for ⌘1 is one too many.
    let keyboardShortcuts: Bool
    /// The dashboard size by default: its call sites (the provider picker, the Agents
    /// source filter) belong to other packages and get the dashboard mockups' size with
    /// no edit. The popover passes `.popover`.
    let metrics: OMSegmentMetrics
    /// What VoiceOver calls the whole control. "Provider" unless the caller names what
    /// the segments choose (the dashboard's range picker: "Time range").
    let containerLabel: String

    /// Which segment keyboard focus is on. nil unless the user is moving through the
    /// control with Tab (Keyboard navigation on); a click does not set it.
    @FocusState private var focusedItemID: String?

    init(
        items: [OMSegmentItem],
        selection: Binding<String>,
        alwaysShowsTitles: Bool = false,
        keyboardShortcuts: Bool = true,
        metrics: OMSegmentMetrics = .dashboard,
        accessibilityLabel: String = "Provider"
    ) {
        self.items = items
        self._selection = selection
        self.alwaysShowsTitles = alwaysShowsTitles
        self.keyboardShortcuts = keyboardShortcuts
        self.metrics = metrics
        self.containerLabel = accessibilityLabel
    }

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

    /// The track under the segments: tinted system glass. `body` draws exactly this
    /// kind through `omGlass`.
    nonisolated static var trackSurface: OMGlassKind { .controlTrack }

    /// The selected segment: a raised pill on the track — not accent blue, and not a
    /// second layer of glass. `SelectedPill` draws exactly this kind through `omGlass`.
    nonisolated static var selectedSurface: OMGlassKind { .raisedPill }

    /// Keyboard focus: the yolk focus ring, not the system accent colour.
    nonisolated static var focusRingToken: OMColorToken { .focusRing }

    /// The selected label reads in the text colour, the others in secondary.
    nonisolated static func labelToken(isSelected: Bool) -> OMColorToken {
        isSelected ? .text : .secondary
    }

    /// A segment with a logo starts closer to it; one without is padded evenly.
    nonisolated static func leadingPadding(hasIcon: Bool, metrics: OMSegmentMetrics) -> CGFloat {
        hasIcon ? metrics.leadingPadding : metrics.trailingPadding
    }

    /// A provider whose session waits for you: a yolk dot just past its logo's top-right.
    nonisolated static var needsYouDotToken: OMColorToken { .accent }
    nonisolated static let needsYouDotDiameter: CGFloat = 6
    /// From the logo's top-right corner: 6 pt right, 2 pt up.
    nonisolated static let needsYouDotOffset = CGSize(width: 6, height: -2)

    private var showsTitles: Bool {
        Self.showsTitles(count: items.count, alwaysShowsTitles: alwaysShowsTitles)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                segment(item, index: index)
            }
        }
        .padding(3)
        .omGlass(Self.trackSurface, in: Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(containerLabel)
    }

    @ViewBuilder
    private func segment(_ item: OMSegmentItem, index: Int) -> some View {
        let isSelected = item.id == selection
        let chrome = Self.segmentChrome(isSelected: isSelected, isFocused: focusedItemID == item.id)
        let hasIcon = item.serviceID != nil
        Button {
            withAnimation(.smooth(duration: 0.2)) { selection = item.id }
        } label: {
            HStack(spacing: metrics.iconTitleSpacing) {
                if let serviceID = item.serviceID {
                    ProviderIconView(serviceID: serviceID, sfFallback: item.sfFallback, size: metrics.iconSize)
                        .overlay(alignment: .topTrailing) {
                            if item.showsDot {
                                Circle()
                                    .fill(.om(Self.needsYouDotToken))
                                    .frame(width: Self.needsYouDotDiameter, height: Self.needsYouDotDiameter)
                                    .offset(Self.needsYouDotOffset)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                // "All" has no icon, so it always keeps its word.
                if showsTitles || !hasIcon {
                    Text(item.title)
                        .font(.system(size: metrics.fontSize, weight: isSelected ? metrics.selectedWeight : metrics.weight))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.om(Self.labelToken(isSelected: isSelected)))
            .padding(.leading, Self.leadingPadding(hasIcon: hasIcon, metrics: metrics))
            .padding(.trailing, metrics.trailingPadding)
            .frame(height: metrics.height)
            .frame(maxWidth: metrics.fillsWidth ? .infinity : nil)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The system's ring is a rectangle around a capsule; the ring below replaces it.
        .focusEffectDisabled()
        .focused($focusedItemID, equals: item.id)
        .modifier(SelectedPill(isSelected: chrome.showsGlass))
        .overlay {
            if chrome.showsFocusRing {
                // A band just outside the capsule, like the mockups' 3 px box-shadow ring.
                Capsule(style: .continuous)
                    .strokeBorder(.om(Self.focusRingToken), lineWidth: OMFocusRing.width)
                    .padding(-OMFocusRing.width)
                    .allowsHitTesting(false)
            }
        }
        .modifier(SegmentShortcut(index: index, enabled: keyboardShortcuts))
        .help(item.title)
        .accessibilityLabel("\(item.title) tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What one segment draws: nothing, the keyboard-focus ring, the selected look, or
/// both. The selected look keeps its 2.7 name, `glass`; since 3.0 it is the raised
/// pill (`OMSegmentedControl.selectedSurface`). Decided by
/// `OMSegmentedControl.segmentChrome(isSelected:isFocused:)`.
enum SegmentChrome: Equatable, Sendable {
    case plain, focusRing, glass, glassAndRing

    var showsGlass: Bool { self == .glass || self == .glassAndRing }
    var showsFocusRing: Bool { self == .focusRing || self == .glassAndRing }
}

/// The raised pill behind the selected segment, nothing behind the others. A change
/// of selection cross-fades it.
private struct SelectedPill: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if isSelected {
            content.omGlass(OMSegmentedControl.selectedSurface, in: Capsule(style: .continuous))
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
            VStack(spacing: 16) {
                OMSegmentedControl(items: [
                    OMSegmentItem(id: "all", title: "All"),
                    OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude", showsDot: true),
                    OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex"),
                    OMSegmentItem(id: "antigravity", title: "Antigravity", serviceID: "antigravity"),
                    OMSegmentItem(id: "grok", title: "Grok", serviceID: "grok"),
                ], selection: $selection, metrics: .popover)
                .frame(width: 332)
                OMSegmentedControl(items: [
                    OMSegmentItem(id: "claude", title: "Claude", serviceID: "claude"),
                    OMSegmentItem(id: "codex", title: "Codex", serviceID: "codex"),
                ], selection: $selection, alwaysShowsTitles: true, keyboardShortcuts: false)
                .fixedSize()
            }
            .padding()
        }
    }
    return Host()
}
