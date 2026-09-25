import SwiftUI
import AppKit

/// The Settings sidebar's metrics (`Settings-General(-Light).dc.html`, `<nav>`): the
/// dashboard's chrome-glass pane and shadows, narrower, 3 pt between items, the app named
/// "Omelette Settings". Its items wear `OMSidebarPillButtonStyle` at the mockup's smaller
/// size.
///
/// Built from the dashboard's primitives rather than by generalising `DashboardSidebar`,
/// which is typed to `DashboardTab` and has a footer this one has none of.
enum SettingsSidebarRules {
    static let width: CGFloat = 196
    static let corner: OMCornerContext = .sidebar
    /// The dashboard sidebar's glass (`DashboardSidebarRules.surface`): chrome, with the
    /// hairline as its light edge.
    static let surface: OMGlassKind = .sidebar
    /// The mockup's items: 32 pt tall, 10 pt in, a 10 pt corner.
    static let itemMetrics: OMSidebarPillMetrics = .settings
    static let topPadding: CGFloat = 16
    static let horizontalPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 14
    static let itemSpacing: CGFloat = 3
    /// Room for the traffic lights, which `WindowButtonsPlacement` moves into this row:
    /// the mockup's 12 pt lights and the 18 pt under them.
    static let windowControlsRowHeight: CGFloat = 30
    static let brandTitle = "Omelette Settings"
    static let brandIconSize: CGFloat = 22
    static let brandSpacing: CGFloat = 9
    static let brandFontSize: CGFloat = 13
    static let brandHorizontalPadding: CGFloat = 8
    static let brandBottomPadding: CGFloat = 12
    static let accessibilityName = "Settings sections"
    /// Keyboard focus on an item: the yolk ring, as on the dashboard sidebar.
    static let focusRingToken: OMColorToken = .focusRing

    /// Whether `tab` wears the focus ring: it holds focus and the user is navigating with
    /// the keyboard (`OMFocusRing.isVisible`). A click leaves no ring.
    static func focusRingVisible(on tab: SettingsTab, focusedTab: SettingsTab?, keyboardNavigation: Bool) -> Bool {
        OMFocusRing.isVisible(isFocused: focusedTab == tab, keyboardNavigation: keyboardNavigation)
    }
}

/// The Settings window's floating sidebar: a chrome-glass pane inset in the window, room
/// for the traffic lights, the app's name and one pill per tab.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab

    /// Which item holds focus. With Keyboard navigation on, a click can leave it on an
    /// item too, so it alone does not decide the ring.
    @FocusState private var focusedTab: SettingsTab?
    /// Whether the user is moving through the sidebar with the keyboard: on with ↑ / ↓
    /// or when a key press (Tab) moved focus in; off with a click.
    @State private var keyboardNavigation = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSidebarRules.itemSpacing) {
            Color.clear
                .frame(height: SettingsSidebarRules.windowControlsRowHeight)
                .accessibilityHidden(true)
            brand
            ForEach(SettingsTab.allCases) { tab in
                item(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SettingsSidebarRules.topPadding)
        .padding(.horizontal, SettingsSidebarRules.horizontalPadding)
        .padding(.bottom, SettingsSidebarRules.bottomPadding)
        .frame(width: SettingsSidebarRules.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .omGlass(SettingsSidebarRules.surface, in: OMCornerShape(SettingsSidebarRules.corner))
        // The dashboard sidebar's drop shadows, outside the pane (Task 6).
        .omSidebarShadow(corner: SettingsSidebarRules.corner)
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
        .accessibilityLabel(SettingsSidebarRules.accessibilityName)
    }

    /// One tab: a raised pill when selected, the yolk ring while keyboard focus is on it,
    /// and ↑ / ↓ to the neighbouring tab, selection and focus together.
    private func item(_ tab: SettingsTab) -> some View {
        Button {
            selection = tab
        } label: {
            Label(tab.rawValue, systemImage: tab.icon)
        }
        .buttonStyle(.omSidebarPill(isSelected: tab == selection, metrics: SettingsSidebarRules.itemMetrics))
        // The system's ring is a rectangle; the ring below follows the pill.
        .focusEffectDisabled()
        .focused($focusedTab, equals: tab)
        .overlay {
            if SettingsSidebarRules.focusRingVisible(on: tab, focusedTab: focusedTab, keyboardNavigation: keyboardNavigation) {
                OMSidebarPillShape(radius: SettingsSidebarRules.itemMetrics.cornerRadius)
                    .strokeBorder(.om(SettingsSidebarRules.focusRingToken), lineWidth: OMFocusRing.width)
                    .padding(-OMFocusRing.width)
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(.upArrow) { move(from: tab, by: -1) }
        .onKeyPress(.downArrow) { move(from: tab, by: 1) }
    }

    private func move(from tab: SettingsTab, by offset: Int) -> KeyPress.Result {
        let next = SettingsTab.step(from: tab, by: offset)
        keyboardNavigation = true
        selection = next
        focusedTab = next
        return .handled
    }

    /// The app's own icon and "Omelette Settings".
    private var brand: some View {
        HStack(spacing: SettingsSidebarRules.brandSpacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: SettingsSidebarRules.brandIconSize, height: SettingsSidebarRules.brandIconSize)
                .accessibilityHidden(true)
            Text(SettingsSidebarRules.brandTitle)
                .font(.system(size: SettingsSidebarRules.brandFontSize, weight: .semibold))
                .foregroundStyle(.om(.text))
        }
        .padding(.horizontal, SettingsSidebarRules.brandHorizontalPadding)
        .padding(.bottom, SettingsSidebarRules.brandBottomPadding)
    }
}
