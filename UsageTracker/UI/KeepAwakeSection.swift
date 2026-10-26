import SwiftUI

/// Keep awake with the lid closed (spec 2026-10-26, § UI): the popover's block between the
/// content and the footer. One status line by state (`KeepAwakeCopy.status`), the failure
/// when there is one, and the steppers with Apply in every state (plan D1), so Apply while
/// armed replaces the deadline and Apply after an end starts a new one.
struct KeepAwakeSection: View {
    @ObservedObject private var model = KeepAwakeModel.shared
    /// The steppers, seeded from the last applied duration on every popover open.
    @State private var parts = KeepAwakeRules.parts(totalMinutes: SettingsStore.shared.keepAwakeDurationMinutes)
    /// Ends up to this moment are dismissed (plan D3). Persisted, because the helper keeps
    /// reporting an end across restarts; the helper is never told.
    @AppStorage(KeepAwakeSection.dismissedEndKey) private var dismissedEndAt: Double = 0

    nonisolated static let dismissedEndKey = "keepAwakeDismissedEndAt"

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
            parts = KeepAwakeRules.parts(totalMinutes: SettingsStore.shared.keepAwakeDurationMinutes)
            await model.refresh()
        }
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
        HStack(spacing: OMSpacing.s) {
            stepper(.days, value: $parts.days)
            stepper(.hours, value: $parts.hours)
            stepper(.minutes, value: $parts.minutes)
            Spacer(minLength: 0)
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
            Button(KeepAwakeCopy.applyButton, action: apply)
                .buttonStyle(.omCapsule(.small))
                .disabled(!KeepAwakeCopy.canApply(days: parts.days, hours: parts.hours, minutes: parts.minutes, isWorking: model.isWorking))
        }
    }

    private func stepper(_ unit: KeepAwakeCopy.StepperUnit, value: Binding<Int>) -> some View {
        Stepper(value: value, in: unit.range) {
            Text(KeepAwakeCopy.stepperValue(value.wrappedValue, unit: unit))
                .font(.system(size: OMKeyValueRow.captionSize))
                .monospacedDigit()
                .foregroundStyle(.om(.text))
        }
        .fixedSize()
        .accessibilityLabel(unit.name)
        .accessibilityValue(KeepAwakeCopy.stepperValue(value.wrappedValue, unit: unit))
    }

    /// Apply also dismisses the last end (spec § Behaviour: "until the next Apply or dismiss").
    private func apply() {
        dismissedEndAt = Date().timeIntervalSince1970
        let parts = self.parts
        Task { await model.arm(days: parts.days, hours: parts.hours, minutes: parts.minutes) }
    }
}
