import SwiftUI

// MARK: - Rules (`Settings-*(-Light).dc.html`)

/// The Settings window around its two columns: 780 pt wide, as tall as each tab's
/// mockup, the sidebar and the page floating `windowInset` inside it as the dashboard's do.
enum SettingsWindowLayout {
    static let width: CGFloat = 780
    /// The dashboard's inset. `WindowButtonsPlacement` places the traffic lights by
    /// `DashboardShellLayout`, so both windows must float their sidebar the same way.
    static let windowInset: CGFloat = DashboardShellLayout.windowInset
    /// The page column's `padding: 22px 28px 28px 30px`.
    static let columnTop: CGFloat = 22
    static let columnTrailing: CGFloat = 28
    static let columnBottom: CGFloat = 28
    static let columnLeading: CGFloat = 30
    /// Between the title and each section (`gap: 22px`).
    static let sectionSpacing: CGFloat = 22
    /// The page title: 22 pt bold, `letter-spacing: -0.3px`.
    static let titleSize: CGFloat = 22
    static let titleTracking: CGFloat = -0.3
    /// Room kept free above and below the window on a screen shorter than the tab.
    static let screenMargin: CGFloat = 40
    /// However small the screen, the sidebar's six items and a page title still fit.
    static let minimumHeight: CGFloat = 420

    /// Each mockup's window height.
    static func mockupHeight(_ tab: SettingsTab) -> CGFloat {
        switch tab {
        case .general: return 600
        case .menuBar: return 680
        case .providers: return 560
        case .notifications: return 960
        case .integrations: return 840
        case .advanced: return 810
        }
    }

    /// The window's height on `tab` (spec: "height per tab"): the mockup's, cut to the
    /// screen's visible height less `screenMargin` (the page scrolls then), never under
    /// `minimumHeight`. No screen known: the mockup's.
    static func height(for tab: SettingsTab, availableHeight: CGFloat?) -> CGFloat {
        let wanted = mockupHeight(tab)
        guard let availableHeight else { return wanted }
        return max(minimumHeight, min(wanted, availableHeight - screenMargin))
    }
}

/// A group of rows: the content fill with its 1 px edge at the popover group's 16 pt
/// corner, rows 16 / 11 pt in, a hairline between rows; the header 13 pt, 4 pt in.
enum SettingsRowRules {
    static let groupCorner: OMCornerContext = .popoverGroup
    static let groupFill: OMColorToken = .contentFill
    static let groupBorder: OMColorToken = .contentBorder
    static let separator: OMColorToken = .hairline
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 11
    static let minimumContentHeight: CGFloat = 30
    /// Between the logo, the text column and the control.
    static let spacing: CGFloat = 12
    /// Between controls on the right (a status and its button, two buttons).
    static let trailingSpacing: CGFloat = 8
    static let titleSize: CGFloat = 13.5
    static let captionSize: CGFloat = 12
    static let captionSpacing: CGFloat = 2
    static let headerSize: CGFloat = 13
    static let headerInset: CGFloat = 4
    /// Header, group and footer caption (`gap: 8px`).
    static let sectionSpacing: CGFloat = 8
    /// Values, statuses and control labels.
    static let valueSize: CGFloat = 12.5
    /// Spec § Settings: "switches use the accent".
    static let switchTint: OMColorToken = .accent
    static let statusDotSize: CGFloat = 7
    static let statusSpacing: CGFloat = 7
    static let buttonSize: OMButtonSize = .small
    static let fieldHeight: CGFloat = 28
    static let fieldCornerRadius: CGFloat = 8
    static let fieldHorizontalPadding: CGFloat = 10
    static let fieldFill: OMColorToken = .track
    static let fieldBorder: OMColorToken = .hairline
    /// A disabled button or stepper half: the capsule style does not dim by itself.
    static let disabledOpacity: Double = 0.45
    /// "Reset" and "Delete": the destructive labels.
    static let destructiveLabel: OMColorToken = .critical
    /// A failed action's message under its row (`SettingsErrorText`): the critical red, at
    /// the caption size, never cut. A status is one line; a failure carries the recovery
    /// sentence and wraps.
    static let errorToken: OMColorToken = .critical
}

/// The threshold stepper (`Settings-Notifications.dc.html`): the figure, then − and +
/// on a capsule track.
enum SettingsStepperRules {
    static let valueSize: CGFloat = 15
    static let unitSize: CGFloat = 10
    static let buttonWidth: CGFloat = 26
    static let buttonHeight: CGFloat = 24
    static let symbolSize: CGFloat = 15
    static let trackPadding: CGFloat = 2
    static let spacing: CGFloat = 8

    /// One step down (`direction` −1) or up (+1), held inside `range` as the system
    /// `Stepper` holds it.
    static func stepped(_ value: Int, by direction: Int, in range: ClosedRange<Int>, step: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value + direction * step))
    }

    /// Whether that step would change anything: false at the end of the range.
    static func canStep(_ value: Int, by direction: Int, in range: ClosedRange<Int>, step: Int) -> Bool {
        stepped(value, by: direction, in: range, step: step) != value
    }

    /// "80%".
    static func figure(_ percent: Int) -> String {
        "\(percent)%"
    }
}

/// Words more than one Settings tab uses.
enum SettingsCopy {
    /// "just now", "12s ago", "4m ago", "2h ago", "3d ago". A clock that runs behind the
    /// date counts as no age at all.
    static func ago(from date: Date, now: Date) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3_600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3_600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }

    /// `path` with the home directory written as "~", as the mockups print paths.
    static func tildePath(_ path: String, home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !base.isEmpty else { return path }
        if path == base { return "~" }
        guard path.hasPrefix(base + "/") else { return path }
        return "~" + path.dropFirst(base.count)
    }
}

// MARK: - Values

/// A state as a dot and a line (spec § Settings: "status is a dot + text (no `OMChip`)").
struct SettingsStatus: Equatable, Sendable {
    let text: String
    let dot: OMColorToken
}

/// A line under a row's title, or under a group, in a colour of its own: a warning, a
/// conflict, a result.
struct SettingsCaption: Equatable, Sendable {
    let text: String
    let token: OMColorToken
}

/// A provider's logo on a row.
struct SettingsLogo: Equatable, Sendable {
    let serviceID: String
    let sfFallback: String
    let boxSize: CGFloat
    let glyphSize: CGFloat
}

/// A link under a row's note ("Copy Omelette's command").
struct SettingsLinkAction {
    let title: String
    let action: @MainActor () -> Void
}

// MARK: - Views

/// One tab's page: its title, then its sections, scrolling when the window is shorter.
struct SettingsPage<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsWindowLayout.sectionSpacing) {
                Text(tab.rawValue)
                    .font(.system(size: SettingsWindowLayout.titleSize, weight: .bold))
                    .tracking(SettingsWindowLayout.titleTracking)
                    .foregroundStyle(.om(.text))
                    .accessibilityAddTraits(.isHeader)
                content()
            }
            .padding(.top, SettingsWindowLayout.columnTop)
            .padding(.leading, SettingsWindowLayout.columnLeading)
            .padding(.trailing, SettingsWindowLayout.columnTrailing)
            .padding(.bottom, SettingsWindowLayout.columnBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Paths, versions and errors are worth copying out, as on the dashboard.
        .textSelection(.enabled)
        // `@AppStorage` inside `SettingsStore` never sends `objectWillChange` (see its
        // `showsRemaining`). 2.x's rows shown only while a switch is on, and its
        // `onChange`s, were redrawn only because the window also watched `AppState`.
        // A defaults write is the store's change: tell everything that observes it. The
        // notification comes on the writing thread (Sparkle writes off the main one), so
        // it hops to the main queue before touching the main-actor store.
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            SettingsStore.shared.objectWillChange.send()
        }
    }
}

/// A titled group of rows with a hairline between them, and a caption and a note under
/// it.
struct SettingsSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    var note: SettingsCaption? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowRules.sectionSpacing) {
            if let header {
                Text(header)
                    .font(.system(size: SettingsRowRules.headerSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .padding(.horizontal, SettingsRowRules.headerInset)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle()
                                .fill(.om(SettingsRowRules.separator))
                                .frame(height: 1)
                                .padding(.horizontal, SettingsRowRules.horizontalPadding)
                                .accessibilityHidden(true)
                        }
                        row
                    }
                }
            }
            .background {
                OMCornerShape(SettingsRowRules.groupCorner)
                    .fill(.om(SettingsRowRules.groupFill))
            }
            .overlay {
                OMCornerShape(SettingsRowRules.groupCorner)
                    .strokeBorder(.om(SettingsRowRules.groupBorder), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            if let footer {
                SettingsCaptionText(caption: SettingsCaption(text: footer, token: .secondary))
                    .padding(.horizontal, SettingsRowRules.headerInset)
            }
            if let note {
                SettingsCaptionText(caption: note)
                    .padding(.horizontal, SettingsRowRules.headerInset)
            }
        }
    }
}

/// A caption line in its colour, wrapping rather than truncating.
struct SettingsCaptionText: View {
    let caption: SettingsCaption

    var body: some View {
        Text(caption.text)
            .font(.system(size: SettingsRowRules.captionSize))
            .foregroundStyle(.om(caption.token))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A failed action's message, in red at the caption size, wrapped over as many lines as
/// it takes. A filesystem error or "isn't valid — … Fix or move it and try again" carries
/// the way out, so it is never cut to one line, unlike a status (`SettingsStatusLabel`).
struct SettingsErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: SettingsRowRules.captionSize))
            .foregroundStyle(.om(SettingsRowRules.errorToken))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row: an optional logo, the title with its caption, note, link and a failed
/// action's message on the left, the row's controls on the right. `help` is the hover
/// text (the 2.x caption, where the mockup cut it to one line).
struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String? = nil
    var note: SettingsCaption? = nil
    var noteAction: SettingsLinkAction? = nil
    /// What the row's last action could not do, in full (`SettingsErrorText`).
    var error: String? = nil
    var logo: SettingsLogo? = nil
    var help: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SettingsRowRules.spacing) {
            if let logo {
                SettingsLogoView(logo: logo)
            }
            VStack(alignment: .leading, spacing: SettingsRowRules.captionSpacing) {
                Text(title)
                    .font(.system(size: SettingsRowRules.titleSize, weight: .medium))
                    .foregroundStyle(.om(.text))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    SettingsCaptionText(caption: SettingsCaption(text: caption, token: .secondary))
                }
                if let note {
                    SettingsCaptionText(caption: note)
                }
                if let noteAction {
                    Button(noteAction.title, action: noteAction.action)
                        .buttonStyle(.omLink)
                }
                if let error {
                    SettingsErrorText(message: error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SettingsRowRules.trailingSpacing) {
                trailing()
            }
            .fixedSize()
        }
        .frame(minHeight: SettingsRowRules.minimumContentHeight)
        .padding(.horizontal, SettingsRowRules.horizontalPadding)
        .padding(.vertical, SettingsRowRules.verticalPadding)
        .modifier(SettingsHelp(text: help))
    }
}

/// A row whose control is a switch: the commonest row in every tab.
struct SettingsSwitchRow: View {
    let title: String
    var caption: String? = nil
    var help: String? = nil
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow(title: title, caption: caption, help: help) {
            SettingsSwitch(label: title, isOn: isOn)
        }
    }
}

/// The system switch in the accent. Its label is hidden on screen and read by VoiceOver.
struct SettingsSwitch: View {
    let label: String
    let isOn: Binding<Bool>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(OMPalette.rgba(SettingsRowRules.switchTint, scheme: colorScheme).color)
    }
}

/// A state: a 7 pt dot in its colour, then its words in secondary, on one line. For
/// statuses only; a failure goes under its row as `SettingsErrorText`.
struct SettingsStatusLabel: View {
    let status: SettingsStatus

    var body: some View {
        HStack(spacing: SettingsRowRules.statusSpacing) {
            Circle()
                .fill(.om(status.dot))
                .frame(width: SettingsRowRules.statusDotSize, height: SettingsRowRules.statusDotSize)
                .accessibilityHidden(true)
            Text(status.text)
                .font(.system(size: SettingsRowRules.valueSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A read-only value on the right of a row ("12 received · 0 dropped").
struct SettingsValueText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: SettingsRowRules.valueSize))
            .foregroundStyle(.om(.secondary))
            .lineLimit(1)
    }
}

/// A provider's logo in its box, in the text colour.
struct SettingsLogoView: View {
    let logo: SettingsLogo

    var body: some View {
        ProviderIconView(serviceID: logo.serviceID, sfFallback: logo.sfFallback, size: logo.glyphSize)
            .foregroundStyle(.om(.text))
            .frame(width: logo.boxSize, height: logo.boxSize)
            .accessibilityHidden(true)
    }
}

/// "80%" and − / + on a capsule track: the 2.x `Stepper`'s range and step. One adjustable
/// element for VoiceOver.
struct SettingsStepper: View {
    let label: String
    let value: Binding<Int>
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: SettingsStepperRules.spacing) {
            OMFigureText(
                text: SettingsStepperRules.figure(value.wrappedValue),
                size: SettingsStepperRules.valueSize,
                unitSize: SettingsStepperRules.unitSize
            )
            HStack(spacing: 0) {
                stepButton("−", direction: -1)
                stepButton("+", direction: 1)
            }
            .padding(SettingsStepperRules.trackPadding)
            .controlTrackGlass(in: Capsule(style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SettingsStepperRules.figure(value.wrappedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, direction: Int) -> some View {
        let enabled = SettingsStepperRules.canStep(value.wrappedValue, by: direction, in: range, step: step)
        return Button {
            move(direction)
        } label: {
            Text(symbol)
                .font(.system(size: SettingsStepperRules.symbolSize, weight: .medium))
                .foregroundStyle(.om(.text))
                .frame(width: SettingsStepperRules.buttonWidth, height: SettingsStepperRules.buttonHeight)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : SettingsRowRules.disabledOpacity)
    }

    private func move(_ direction: Int) {
        value.wrappedValue = SettingsStepperRules.stepped(value.wrappedValue, by: direction, in: range, step: step)
    }
}

/// A row's button: the popover's small capsule on control-track glass, dimmed while
/// disabled. `Button { } label: { Text("Reset").foregroundStyle(.om(.critical)) }` keeps
/// its own colour: the label's style is the innermost.
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration)
    }
}

/// Reads `isEnabled` in a view, where the environment is guaranteed.
private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        OMCapsuleButtonStyle(size: SettingsRowRules.buttonSize)
            .makeBody(configuration: configuration)
            .opacity(isEnabled ? 1 : SettingsRowRules.disabledOpacity)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
}

/// A text field's focus (session ruling S12). A plain field draws no system ring, and on
/// the track fill the caret alone is hard to find, so a focused field wears the yolk ring.
/// There is no keyboard-navigation gate, unlike the sidebar and the segmented controls: a
/// field someone clicked is focused by intent.
enum SettingsFieldRules {
    static let focusRingToken: OMColorToken = .focusRing
    /// Concentric with the field: its 8 pt corner plus the ring's width.
    static let focusRingCornerRadius: CGFloat = SettingsRowRules.fieldCornerRadius + OMFocusRing.width

    /// The identity. It is kept as a named rule so the view states the decision (focus
    /// alone, no keyboard gate) where the other rings call `OMFocusRing.isVisible`. It has
    /// no test: a test of it would restate `isFocused`.
    static func showsFocusRing(isFocused: Bool) -> Bool {
        isFocused
    }
}

/// A text field as the mockups draw it: 28 pt tall, 8 pt corners, the track fill and a
/// hairline edge; the yolk ring outside it while it holds focus.
struct SettingsFieldStyle: ViewModifier {
    let width: CGFloat
    var monospaced = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: SettingsRowRules.valueSize, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.om(.text))
            .padding(.horizontal, SettingsRowRules.fieldHorizontalPadding)
            .frame(width: width, height: SettingsRowRules.fieldHeight)
            .background {
                RoundedRectangle(cornerRadius: SettingsRowRules.fieldCornerRadius, style: .continuous)
                    .fill(.om(SettingsRowRules.fieldFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsRowRules.fieldCornerRadius, style: .continuous)
                    .strokeBorder(.om(SettingsRowRules.fieldBorder), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if SettingsFieldRules.showsFocusRing(isFocused: isFocused) {
                    RoundedRectangle(cornerRadius: SettingsFieldRules.focusRingCornerRadius, style: .continuous)
                        .strokeBorder(.om(SettingsFieldRules.focusRingToken), lineWidth: OMFocusRing.width)
                        .padding(-OMFocusRing.width)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// `.help` only when there is something to say.
private struct SettingsHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
