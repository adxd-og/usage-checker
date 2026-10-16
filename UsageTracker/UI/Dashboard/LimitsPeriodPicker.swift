import SwiftUI

/// One entry of the period picker: a period and its name (`LimitsCopy.periodName`).
struct LimitsPeriodEntry: Identifiable, Equatable {
    let period: LimitsPeriod
    let name: String
    var id: LimitsPeriod { period }
}

/// The period picker (`Dashboard-Limits(-Light).dc.html`: a capsule beside the window
/// switch reading "This week" with an up-and-down chevron; spec 2026-10-16 limit
/// analytics § The tab, item 1): a menu of the periods on offer, newest first, the picked
/// one ticked.
struct LimitsPeriodPicker: View {
    let entries: [LimitsPeriodEntry]
    @Binding var selection: LimitsPeriod

    private var selectedName: String {
        entries.first { $0.period == selection }?.name ?? entries.first?.name ?? ""
    }

    var body: some View {
        Menu {
            ForEach(entries) { entry in
                Button {
                    selection = entry.period
                } label: {
                    if entry.period == selection {
                        Label(entry.name, systemImage: "checkmark")
                    } else {
                        Text(entry.name)
                    }
                }
            }
        } label: {
            HStack(spacing: LimitsLayout.periodPickerSpacing) {
                Text(selectedName)
                    .font(.system(size: LimitsLayout.periodPickerTextSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: LimitsLayout.periodPickerChevronSize, weight: .semibold))
                    .foregroundStyle(.om(.secondary))
                    .accessibilityHidden(true)
            }
            .padding(.leading, LimitsLayout.periodPickerLeading)
            .padding(.trailing, LimitsLayout.periodPickerTrailing)
            .frame(height: LimitsLayout.periodPickerHeight)
            .omGlass(OMSegmentedControl.trackSurface, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(LimitsCopy.periodPickerLabel)
        .accessibilityValue(selectedName)
    }
}
