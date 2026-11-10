import SwiftUI

/// Settings › Pet's words and onboarding's step (notch-island spec 2026-10-29 § 3.6, § 3.7).
enum PetSettingsCopy {
    static let petTitle = "Show the pet"
    static let petCaption = "In the island's left column, on a screen wide enough for it."
    static let earsTitle = "Ears beside the notch"
    static let pickerHeader = "Your pet"
    static let onboardingTitle = "Pick your pet"
    static let onboardingCaption = "It lives beside your limits. Change it any time in Settings › \(SettingsTab.pet.rawValue)."

    static func earsCaption(islandDisplayAttached: Bool) -> String {
        islandDisplayAttached
            ? "With the island closed: a waiting agent, a signed-out Claude, a limit at 90 %, keep awake."
            : "Only while a display shows the island."
    }
}

/// Settings › Pet (§ 3.7): on or off, the ears on or off, the animal and palette.
struct PetSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// Whether a display shows the island (spec 2026-11-03): the ears' caption follows it, a flip of
    /// Island on displays without a notch included (spec 2026-11-10 § A, B1).
    @ObservedObject private var presence = IslandDisplayPresence.shared

    var body: some View {
        SettingsPage(tab: .pet) {
            SettingsSection {
                SettingsSwitchRow(
                    title: PetSettingsCopy.petTitle,
                    caption: PetSettingsCopy.petCaption,
                    isOn: $settings.petEnabled
                )
                SettingsSwitchRow(
                    title: PetSettingsCopy.earsTitle,
                    caption: PetSettingsCopy.earsCaption(islandDisplayAttached: presence.islandDisplayAttached),
                    isOn: $settings.earsEnabled
                )
            }
            SettingsSection(header: PetSettingsCopy.pickerHeader) {
                PetPickerView(dimmed: !settings.petEnabled)
                    .padding(SettingsRowRules.verticalPadding)
            }
        }
    }
}
