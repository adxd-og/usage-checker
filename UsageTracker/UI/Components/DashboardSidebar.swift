import SwiftUI
import AppKit

/// The dashboard sidebar's metrics and surface, from `Dashboard-Overview(-Light).dc.html`
/// (liquid-glass spec § Components, "Sidebar"). Its items wear `OMSidebarPillButtonStyle`.
enum DashboardSidebarRules {
    static let width: CGFloat = 224
    static let corner: OMCornerContext = .sidebar
    /// Chrome glass as every dashboard mockup's `<nav>` draws it, with the hairline as its
    /// light edge (`OMGlassKind.sidebar`, ruling R4); pane glass is the cards'.
    static let surface: OMGlassKind = .sidebar
    static let topPadding: CGFloat = 16
    static let horizontalPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 14
    static let itemSpacing: CGFloat = 4
    /// Room for the window's traffic lights, which `WindowButtonsPlacement` moves into
    /// this row: the mockups' 12 pt lights and the 18 pt under them (AppKit's are 14).
    static let windowControlsRowHeight: CGFloat = 30
    static let brandTitle = "Omelette"
    static let brandIconSize: CGFloat = 24
    static let brandSpacing: CGFloat = 9
    static let brandFontSize: CGFloat = 13.5
    static let brandHorizontalPadding: CGFloat = 8
    static let brandBottomPadding: CGFloat = 14
    /// Where the app-name row starts below the panel's top edge: the padding, the
    /// lights row and one row gap, as the sidebar's stack lays them out (the mockups'
    /// 16 + 30 + 4). It clears the traffic lights, which sit `windowButtonsPadding`
    /// below the same edge.
    static var appNameRowTop: CGFloat { topPadding + windowControlsRowHeight + itemSpacing }
    static let accessibilityName = "Sidebar"
    /// Keyboard focus on an item: the yolk ring, as on the segmented controls.
    static let focusRingToken: OMColorToken = .focusRing
}

/// The dashboard's floating sidebar: a chrome-glass pane inset in the window, room for
/// the traffic lights, the app's name, one pill per tab, and `footer` at the bottom.
struct DashboardSidebar<Footer: View>: View {
    @Binding var selection: DashboardTab
    @ViewBuilder var footer: () -> Footer

    @Environment(\.colorScheme) private var colorScheme

    /// Which item keyboard focus is on. nil unless the user moves through the window
    /// with Tab (Keyboard navigation on); a click does not set it.
    @FocusState private var focusedTab: DashboardTab?

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardSidebarRules.itemSpacing) {
            Color.clear
                .frame(height: DashboardSidebarRules.windowControlsRowHeight)
                .accessibilityHidden(true)
            brand
            ForEach(DashboardTab.allCases) { tab in
                item(tab)
            }
            Spacer(minLength: 0)
            footer()
        }
        .padding(.top, DashboardSidebarRules.topPadding)
        .padding(.horizontal, DashboardSidebarRules.horizontalPadding)
        .padding(.bottom, DashboardSidebarRules.bottomPadding)
        .frame(width: DashboardSidebarRules.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .omGlass(DashboardSidebarRules.surface, in: OMCornerShape(DashboardSidebarRules.corner))
        .background { shadowCaster }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DashboardSidebarRules.accessibilityName)
    }

    /// One tab: a raised pill when selected, the yolk ring while keyboard focus is on
    /// it, and ↑ / ↓ to the neighbouring tab, selection and focus together, as the 2.x
    /// sidebar list moved.
    private func item(_ tab: DashboardTab) -> some View {
        Button {
            selection = tab
        } label: {
            Label(tab.rawValue, systemImage: tab.icon)
        }
        .buttonStyle(.omSidebarPill(isSelected: tab == selection))
        // The system's ring is a rectangle; the ring below follows the pill.
        .focusEffectDisabled()
        .focused($focusedTab, equals: tab)
        .overlay {
            if focusedTab == tab {
                OMCornerShape(.navItem)
                    .strokeBorder(.om(DashboardSidebarRules.focusRingToken), lineWidth: OMFocusRing.width)
                    .padding(-OMFocusRing.width)
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(.upArrow) { move(from: tab, by: -1) }
        .onKeyPress(.downArrow) { move(from: tab, by: 1) }
    }

    private func move(from tab: DashboardTab, by offset: Int) -> KeyPress.Result {
        let next = DashboardTab.step(from: tab, by: offset)
        selection = next
        focusedTab = next
        return .handled
    }

    /// The mockups' drop shadows (`OMGlass.sidebarShadows`), outside the sidebar only,
    /// as a CSS `box-shadow` paints them. System glass draws no recipe shadow, and a
    /// shadow on the glass itself would shade every glyph on it, so opaque shapes behind
    /// the glass cast the shadows and a reverse mask removes everything inside the
    /// sidebar's shape. The casters add nothing under the glass: the backdrop and the
    /// window's one tint show through it untouched. The mask reaches three shadow radii
    /// (the Gaussian's visible tail) plus the offset beyond the sidebar, so the halo is
    /// clipped only past three blur radii. The casters are inset 1 pt from the mask's
    /// cutout because both edges are anti-aliased: partial coverage on each would leave
    /// residual black on the edge pixels, a dark fringe against the backdrop.
    private var shadowCaster: some View {
        let shadows = OMGlass.sidebarShadows(scheme: colorScheme)
        let shape = OMCornerShape(DashboardSidebarRules.corner)
        let reach = shadows
            .map { 3 * OMGlassRules.shadowRadius(cssBlur: $0.blur) + abs($0.y) }
            .max() ?? 0
        return ZStack {
            ForEach(Array(shadows.enumerated()), id: \.offset) { _, shadow in
                // Opaque only to give the shadow its silhouette; the mask removes it.
                shape
                    .inset(by: 1)
                    .fill(Color.black)
                    .shadow(
                        color: shadow.color.color,
                        radius: OMGlassRules.shadowRadius(cssBlur: shadow.blur),
                        x: 0,
                        y: shadow.y
                    )
            }
        }
        .mask {
            ZStack {
                Rectangle().padding(-reach)
                shape.blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The app's own icon, as the popover header shows it, and its name.
    private var brand: some View {
        HStack(spacing: DashboardSidebarRules.brandSpacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: DashboardSidebarRules.brandIconSize, height: DashboardSidebarRules.brandIconSize)
                .accessibilityHidden(true)
            Text(DashboardSidebarRules.brandTitle)
                .font(.system(size: DashboardSidebarRules.brandFontSize, weight: .semibold))
                .foregroundStyle(.om(.text))
        }
        .padding(.horizontal, DashboardSidebarRules.brandHorizontalPadding)
        .padding(.bottom, DashboardSidebarRules.brandBottomPadding)
    }
}
