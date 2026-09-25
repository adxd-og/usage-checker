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

    /// Whether `tab` wears the focus ring: it holds focus and the user is navigating with
    /// the keyboard (`OMFocusRing.isVisible`). A click leaves no ring.
    static func focusRingVisible(on tab: DashboardTab, focusedTab: DashboardTab?, keyboardNavigation: Bool) -> Bool {
        OMFocusRing.isVisible(isFocused: focusedTab == tab, keyboardNavigation: keyboardNavigation)
    }
}

/// The dashboard's floating sidebar: a chrome-glass pane inset in the window, room for
/// the traffic lights, the app's name, one pill per tab, and `footer` at the bottom.
struct DashboardSidebar<Footer: View>: View {
    @Binding var selection: DashboardTab
    @ViewBuilder var footer: () -> Footer

    /// Which item holds focus. With Keyboard navigation on a click can leave it on an
    /// item too, so it alone does not decide the ring.
    @FocusState private var focusedTab: DashboardTab?
    /// Whether the user is moving through the sidebar with the keyboard: on with ↑ / ↓
    /// or when a key press (Tab) moved focus in; off with a click.
    @State private var keyboardNavigation = false

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
        .omSidebarShadow(corner: DashboardSidebarRules.corner)
        // The ring follows the input: focus a key press moved in turns it on, a click
        // turns it off (↑ / ↓ turn it on in `move`).
        .onChange(of: focusedTab) { _, focused in
            keyboardNavigation = OMFocusRing.keyboardNavigation(
                afterFocusMovedTo: focused != nil,
                byKeyPress: NSApp.currentEvent?.type == .keyDown
            )
        }
        .simultaneousGesture(TapGesture().onEnded { keyboardNavigation = false })
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
            if DashboardSidebarRules.focusRingVisible(on: tab, focusedTab: focusedTab, keyboardNavigation: keyboardNavigation) {
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
        keyboardNavigation = true
        selection = next
        focusedTab = next
        return .handled
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
