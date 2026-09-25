import SwiftUI

/// Settings › Notifications' words (`Settings-Notifications(-Light).dc.html`). The 2.x
/// captions the mockup cut to one line are kept as hover help.
enum NotificationsSettingsCopy {
    struct LeadOption: Equatable, Hashable, Sendable {
        let minutes: Int
        let label: String
    }

    static let limitsHeader = "Limits"
    static let limitsTitle = "Notify when limits get close"
    static let firstWarningTitle = "First warning"
    static let finalWarningTitle = "Final warning"
    static let firstWarningRange = 50...90
    static let firstWarningStep = 5
    static let finalWarningRange = 80...99
    static let finalWarningStep = 1
    static let limitsFooter = "One notification per window when it crosses a threshold."

    static let timingHeader = "Session timing"
    static let paceTitle = "Warn when the session is burning fast"
    static let paceCaption = "Only when you'd hit the limit before the window resets."
    static let paceHelp = "Fires only when you'd hit the limit before the window resets — a pace that resets in time isn't a problem."
    static let leadTitle = "Warn this far ahead"
    static let leadOptions: [LeadOption] = [
        LeadOption(minutes: 15, label: "15 min"),
        LeadOption(minutes: 30, label: "30 min"),
        LeadOption(minutes: 45, label: "45 min"),
        LeadOption(minutes: 60, label: "1 hour"),
    ]
    static let resetTitle = "Tell me when the window is about to reset"
    static let resetHelp = "Fires in the last 15 minutes of a window you're already pressed against."

    static let agentsHeader = "Agents"
    static let needsYouTitle = "When an agent needs you"
    static let needsYouHelp = "\"Needs you\" fires when a session stops for a permission decision — that one ignores quiet hours by default, because an agent that waits all night has wasted the night."
    static let bypassQuietTitle = "Even during quiet hours"
    static let doneTitle = "When an agent finishes a turn"
    static let doneHelp = "Finished-turn alerts fire on every reply, so they start off."

    static let quietHeader = "Quiet hours and summary"
    static let quietTitle = "Silence notifications at night"
    static let quietHelp = "Every alert — thresholds, session timing and the daily summary — is suppressed during quiet hours."
    static let quietFromTitle = "From"
    static let quietTo = "to"
    static let quietFromLabel = "Quiet hours from"
    static let quietToLabel = "Quiet hours to"

    static let hours = Array(0..<24)

    /// "09:00".
    static func hour(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    static func dailySummaryTitle(hour: Int) -> String {
        "Daily summary at \(self.hour(hour))"
    }
}

/// Settings › Notifications: 2.x Notifications, plus the agent alerts from 2.x Agents ›
/// Alerts. A row that only matters while its switch is on still appears only then.
struct NotificationsSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        SettingsPage(tab: .notifications) {
            limits
            timing
            agents
            quietHours
        }
    }

    private var limits: some View {
        SettingsSection(
            header: NotificationsSettingsCopy.limitsHeader,
            footer: settings.notificationsEnabled ? NotificationsSettingsCopy.limitsFooter : nil
        ) {
            SettingsSwitchRow(title: NotificationsSettingsCopy.limitsTitle, isOn: $settings.notificationsEnabled)
            if settings.notificationsEnabled {
                SettingsRow(title: NotificationsSettingsCopy.firstWarningTitle) {
                    SettingsStepper(
                        label: NotificationsSettingsCopy.firstWarningTitle,
                        value: $settings.threshold80,
                        range: NotificationsSettingsCopy.firstWarningRange,
                        step: NotificationsSettingsCopy.firstWarningStep
                    )
                }
                SettingsRow(title: NotificationsSettingsCopy.finalWarningTitle) {
                    SettingsStepper(
                        label: NotificationsSettingsCopy.finalWarningTitle,
                        value: $settings.threshold95,
                        range: NotificationsSettingsCopy.finalWarningRange,
                        step: NotificationsSettingsCopy.finalWarningStep
                    )
                }
            }
        }
    }

    private var timing: some View {
        SettingsSection(header: NotificationsSettingsCopy.timingHeader) {
            SettingsSwitchRow(
                title: NotificationsSettingsCopy.paceTitle,
                caption: NotificationsSettingsCopy.paceCaption,
                help: NotificationsSettingsCopy.paceHelp,
                isOn: $settings.paceAlertsEnabled
            )
            if settings.paceAlertsEnabled {
                SettingsRow(title: NotificationsSettingsCopy.leadTitle) {
                    Picker(NotificationsSettingsCopy.leadTitle, selection: $settings.paceAlertLeadMinutes) {
                        ForEach(NotificationsSettingsCopy.leadOptions, id: \.minutes) { option in
                            Text(option.label).tag(option.minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsSwitchRow(
                title: NotificationsSettingsCopy.resetTitle,
                help: NotificationsSettingsCopy.resetHelp,
                isOn: $settings.resetAlertsEnabled
            )
        }
    }

    private var agents: some View {
        SettingsSection(header: NotificationsSettingsCopy.agentsHeader) {
            SettingsSwitchRow(
                title: NotificationsSettingsCopy.needsYouTitle,
                help: NotificationsSettingsCopy.needsYouHelp,
                isOn: $settings.agentsNotifyNeedsYou
            )
            if settings.agentsNotifyNeedsYou {
                SettingsSwitchRow(
                    title: NotificationsSettingsCopy.bypassQuietTitle,
                    isOn: $settings.agentsNeedsYouBypassQuietHours
                )
            }
            SettingsSwitchRow(
                title: NotificationsSettingsCopy.doneTitle,
                help: NotificationsSettingsCopy.doneHelp,
                isOn: $settings.agentsNotifyDone
            )
        }
    }

    private var quietHours: some View {
        SettingsSection(header: NotificationsSettingsCopy.quietHeader) {
            SettingsSwitchRow(
                title: NotificationsSettingsCopy.quietTitle,
                help: NotificationsSettingsCopy.quietHelp,
                isOn: $settings.quietHoursEnabled
            )
            if settings.quietHoursEnabled {
                SettingsRow(title: NotificationsSettingsCopy.quietFromTitle) {
                    hourPicker(NotificationsSettingsCopy.quietFromLabel, selection: $settings.quietHoursStart)
                    Text(NotificationsSettingsCopy.quietTo)
                        .font(.system(size: SettingsRowRules.valueSize))
                        .foregroundStyle(.om(.secondary))
                    hourPicker(NotificationsSettingsCopy.quietToLabel, selection: $settings.quietHoursEnd)
                }
            }
            SettingsSwitchRow(
                title: NotificationsSettingsCopy.dailySummaryTitle(hour: settings.dailySummaryHour),
                isOn: $settings.dailySummaryEnabled
            )
        }
    }

    private func hourPicker(_ label: String, selection: Binding<Int>) -> some View {
        Picker(label, selection: selection) {
            ForEach(NotificationsSettingsCopy.hours, id: \.self) { hour in
                Text(NotificationsSettingsCopy.hour(hour)).tag(hour)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}
