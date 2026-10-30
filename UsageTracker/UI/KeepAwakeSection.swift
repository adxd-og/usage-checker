import SwiftUI

/// Keep awake with the lid closed (spec 2026-10-26, § UI) as the island's card
/// (notch-island spec 2026-10-29 § 3.3, Keep-awake card): the title, one status line by
/// state (`KeepAwakeCopy.status`) and the failure when there is one at the top; the fields
/// with Apply — and Cancel while armed, and the spinner while a request runs — at the
/// card's bottom, which reaches the agents card's (owner, prototype v9).
/// `KeepAwakeCardLayout` says whether fields and buttons share a row. Behaviour unchanged:
/// Apply in every state (plan D1), so Apply while armed replaces the deadline and Apply
/// after an end starts a new one; a total over the ceiling is applied as the ceiling, and
/// the fields redraw in canonical form after Apply.
struct KeepAwakeSection: View {
    /// The card's width inside its padding (`ProviderGridRules.LowerRow.keepAwakeInterior`).
    let interiorWidth: CGFloat
    /// The card's own height before the grid stretches it (`KeepAwakeCardLayout.naturalHeight`),
    /// for `IslandHeightRules`; nil until both halves have measured themselves.
    var onNaturalHeight: (CGFloat?) -> Void = { _ in }

    @ObservedObject private var model = KeepAwakeModel.shared
    /// The fields' text, seeded from the last applied duration on every island open and read
    /// on every keystroke through `KeepAwakeCopy.fieldNumber`, so Apply sees what is typed.
    @State private var daysText = Self.seedText.days
    @State private var hoursText = Self.seedText.hours
    @State private var minutesText = Self.seedText.minutes
    /// Ends up to this moment are dismissed (plan D3). Persisted, because the helper keeps
    /// reporting an end across restarts; the helper is never told.
    @AppStorage(KeepAwakeSection.dismissedEndKey) private var dismissedEndAt: Double = 0
    /// The status block's and the controls' own heights, as last laid out.
    @State private var topHeight: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0

    nonisolated static let dismissedEndKey = "keepAwakeDismissedEndAt"

    private var parts: KeepAwakeRules.Parts {
        KeepAwakeRules.Parts(
            days: KeepAwakeCopy.fieldNumber(daysText),
            hours: KeepAwakeCopy.fieldNumber(hoursText),
            minutes: KeepAwakeCopy.fieldNumber(minutesText)
        )
    }

    private static var seedText: (days: String, hours: String, minutes: String) {
        let parts = KeepAwakeRules.parts(totalMinutes: SettingsStore.shared.keepAwakeDurationMinutes)
        return (String(parts.days), String(parts.hours), String(parts.minutes))
    }

    /// Fields and buttons on one row, or two, from the widths this Mac's font gives them.
    private var arrangement: KeepAwakeCardLayout.Arrangement {
        KeepAwakeCardLayout.arrangement(interiorWidth: interiorWidth, widths: KeepAwakeCardLayout.measuredWidths())
    }

    /// The card's own height once both halves have measured themselves.
    private var naturalHeight: CGFloat? {
        guard topHeight > 0, controlsHeight > 0 else { return nil }
        return KeepAwakeCardLayout.naturalHeight(top: topHeight, controls: controlsHeight)
    }

    /// Armed now: Cancel shows beside Apply.
    private var isArmed: Bool {
        let status = KeepAwakeCopy.status(
            registration: model.registration, state: model.state, dismissedThrough: dismissedEndAt, now: Date()
        )
        if case .armed = status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: OMSpacing.s) {
                OMSectionHeader(title: KeepAwakeCopy.title)
                TimelineView(.periodic(from: KeepAwakeCopy.tickAnchor(deadline: model.state.deadline, now: Date()), by: 60)) { context in
                    statusRow(
                        KeepAwakeCopy.status(
                            registration: model.registration,
                            state: model.state,
                            dismissedThrough: dismissedEndAt,
                            now: context.date
                        ),
                        now: context.date
                    )
                }
                if let failure = model.failure {
                    Text(KeepAwakeFailureCopy.text(failure))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.om(.critical))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                topHeight = height
            }
            // The controls sit at the card's bottom when the row stretches it.
            Spacer(minLength: KeepAwakeCardLayout.controlsGap)
            controls
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    controlsHeight = height
                }
        }
        .padding(KeepAwakeCardLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .popoverSurface(.group)
        .onChange(of: naturalHeight, initial: true) { _, height in
            onNaturalHeight(height)
        }
        .task {
            (daysText, hoursText, minutesText) = Self.seedText
            await model.refresh()
        }
        // Every keystroke lands in the state first and is then rewritten through
        // `KeepAwakeCopy.fieldText`; writing the state (not a binding setter that keeps
        // it) is what makes the field redraw with the capped or refused text.
        .onChange(of: daysText) { old, new in cap(&daysText, old: old, new: new, unit: .days) }
        .onChange(of: hoursText) { old, new in cap(&hoursText, old: old, new: new, unit: .hours) }
        .onChange(of: minutesText) { old, new in cap(&minutesText, old: old, new: new, unit: .minutes) }
    }

    private func cap(_ text: inout String, old: String, new: String, unit: KeepAwakeCopy.DurationUnit) {
        let fixed = KeepAwakeCopy.fieldText(new, previous: old, unit: unit)
        if fixed != new { text = fixed }
    }

    @ViewBuilder
    private func statusRow(_ status: KeepAwakeCopy.Status, now: Date) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .armed(let deadline):
            Text(KeepAwakeCopy.armedLine(deadline: deadline, now: now))
                .font(.system(size: OMKeyValueRow.labelSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.om(.text))
                .fixedSize(horizontal: false, vertical: true)
        case .approval:
            VStack(alignment: .leading, spacing: OMSpacing.s) {
                Text(KeepAwakeCopy.approvalText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Button(KeepAwakeCopy.openLoginItemsButton) { model.openLoginItems() }
                    .buttonStyle(.omCapsule(.small))
            }
        case .ended(let at, let reason):
            HStack(alignment: .firstTextBaseline) {
                Text(KeepAwakeCopy.endedLine(at: at, reason: reason, now: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: OMSpacing.s)
                Button(KeepAwakeCopy.dismissButton) { dismissedEndAt = Date().timeIntervalSince1970 }
                    .buttonStyle(.omText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.om(.secondary))
            }
        }
    }

    /// The fields, then Apply, Cancel while armed and the spinner while a request runs: on
    /// one row or the buttons under the fields (`arrangement`); the entry notice under both.
    private var controls: some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            switch arrangement {
            case .oneRow:
                HStack(spacing: KeepAwakeCardLayout.spacing) {
                    fields
                    Spacer(minLength: 0)
                    buttons
                }
            case .twoRows:
                fields
                buttons
            }
            if let notice = KeepAwakeCopy.entryNotice(days: parts.days, hours: parts.hours, minutes: parts.minutes) {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fields: some View {
        HStack(spacing: KeepAwakeCardLayout.spacing) {
            field(.days, text: $daysText)
            field(.hours, text: $hoursText)
            field(.minutes, text: $minutesText)
        }
    }

    private var buttons: some View {
        HStack(spacing: KeepAwakeCardLayout.spacing) {
            // The capsule style does not dim by itself (SettingsRowRules.disabledOpacity):
            // a disabled Apply must look disabled, or 7 d 24 h reads as applicable.
            let canApply = KeepAwakeCopy.canApply(days: parts.days, hours: parts.hours, minutes: parts.minutes, isWorking: model.isWorking)
            Button(KeepAwakeCopy.applyButton, action: apply)
                .buttonStyle(.omCapsule(.small))
                .disabled(!canApply)
                .opacity(canApply ? 1 : SettingsRowRules.disabledOpacity)
            if isArmed {
                Button(KeepAwakeCopy.cancelButton) { Task { await model.cancel() } }
                    .buttonStyle(.omCapsule(.small))
                    .disabled(model.isWorking)
                    .opacity(model.isWorking ? SettingsRowRules.disabledOpacity : 1)
            }
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// A number typed by hand and its unit, read as typed.
    private func field(_ unit: KeepAwakeCopy.DurationUnit, text: Binding<String>) -> some View {
        HStack(spacing: KeepAwakeCardLayout.unitSpacing) {
            TextField(KeepAwakeCopy.fieldPlaceholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: OMKeyValueRow.captionSize))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: KeepAwakeCardLayout.fieldWidth)
                .accessibilityLabel(unit.name)
                .accessibilityValue(KeepAwakeCopy.unitValue(KeepAwakeCopy.fieldNumber(text.wrappedValue), unit: unit))
            Text(unit.symbol)
                .font(.system(size: OMKeyValueRow.captionSize))
                .foregroundStyle(.om(.secondary))
        }
    }

    /// Apply also dismisses the last end (spec § Behaviour: "until the next Apply or dismiss").
    private func apply() {
        dismissedEndAt = Date().timeIntervalSince1970
        let parts = self.parts
        Task {
            await model.arm(days: parts.days, hours: parts.hours, minutes: parts.minutes)
            (daysText, hoursText, minutesText) = Self.seedText
        }
    }
}
