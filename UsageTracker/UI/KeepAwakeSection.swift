import SwiftUI

/// Keep awake with the lid closed (spec 2026-10-26, § UI): the popover's block between the
/// content and the footer. One status line by state (`KeepAwakeCopy.status`), the failure
/// when there is one, and the fields with Apply in every state (plan D1), so Apply while
/// armed replaces the deadline and Apply after an end starts a new one.
struct KeepAwakeSection: View {
    @ObservedObject private var model = KeepAwakeModel.shared
    /// The fields' text, seeded from the last applied duration on every popover open and read
    /// on every keystroke through `KeepAwakeCopy.fieldNumber`, so Apply sees what is typed.
    @State private var daysText = Self.seedText.days
    @State private var hoursText = Self.seedText.hours
    @State private var minutesText = Self.seedText.minutes
    /// Ends up to this moment are dismissed (plan D3). Persisted, because the helper keeps
    /// reporting an end across restarts; the helper is never told.
    @AppStorage(KeepAwakeSection.dismissedEndKey) private var dismissedEndAt: Double = 0

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

    var body: some View {
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
            controls
        }
        .padding(PopoverView.groupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverSurface(.group)
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
            HStack {
                Text(KeepAwakeCopy.armedLine(deadline: deadline, now: now))
                    .font(.system(size: OMKeyValueRow.labelSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.om(.text))
                Spacer(minLength: OMSpacing.s)
                Button(KeepAwakeCopy.cancelButton) { Task { await model.cancel() } }
                    .buttonStyle(.omCapsule(.small))
                    .disabled(model.isWorking)
            }
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
            HStack {
                Text(KeepAwakeCopy.endedLine(at: at, reason: reason, now: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.secondary))
                Spacer(minLength: OMSpacing.s)
                Button(KeepAwakeCopy.dismissButton) { dismissedEndAt = Date().timeIntervalSince1970 }
                    .buttonStyle(.omText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.om(.secondary))
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            HStack(spacing: OMSpacing.s) {
                field(.days, text: $daysText)
                field(.hours, text: $hoursText)
                field(.minutes, text: $minutesText)
                Spacer(minLength: 0)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Button(KeepAwakeCopy.applyButton, action: apply)
                    .buttonStyle(.omCapsule(.small))
                    .disabled(!KeepAwakeCopy.canApply(days: parts.days, hours: parts.hours, minutes: parts.minutes, isWorking: model.isWorking))
            }
            if let notice = KeepAwakeCopy.entryNotice(days: parts.days, hours: parts.hours, minutes: parts.minutes) {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A number typed by hand and its unit, read as typed.
    private func field(_ unit: KeepAwakeCopy.DurationUnit, text: Binding<String>) -> some View {
        HStack(spacing: 3) {
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: OMKeyValueRow.captionSize))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
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
        Task { await model.arm(days: parts.days, hours: parts.hours, minutes: parts.minutes) }
    }
}
