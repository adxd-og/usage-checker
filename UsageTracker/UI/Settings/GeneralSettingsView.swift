import KeyboardShortcuts
import SwiftUI

/// Settings › General's words (`Settings-General(-Light).dc.html`).
enum GeneralSettingsCopy {
    static let startupHeader = "Startup"
    static let launchAtLoginTitle = "Launch at login"
    static let shortcutTitle = "Open the popover"
    static let shortcutCaption = "Works from any app. Unset by default."
    /// While the recorder listens: the way out the library offers but does not show
    /// (Esc ends recording, Delete clears the shortcut).
    static let shortcutRecordingCaption = "Press the keys. Esc cancels, Delete clears."
    static let shortcutWidth: CGFloat = 160

    /// Posted on the default centre by KeyboardShortcuts 2.x's recorder when it starts and
    /// stops recording, with `isActive` in its user info (`RecorderCocoa`,
    /// `recorderActiveStatusDidChange`). The library keeps the constant internal, so the
    /// row names it. Should a later version rename it, the caption stays the resting one.
    static let recorderActivityNotification = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")

    /// Whether an announcement from the recorder means it is recording. Anything but a
    /// `true` flag means it is not, so the caption never outlives the recording.
    static func isRecording(_ userInfo: [AnyHashable: Any]?) -> Bool {
        userInfo?["isActive"] as? Bool ?? false
    }

    /// The shortcut row's caption: the mockup's at rest, how to get out while recording.
    static func shortcutRowCaption(isRecording: Bool) -> String {
        isRecording ? shortcutRecordingCaption : shortcutCaption
    }
    static let refreshHeader = "Refresh"
    static let refreshTitle = "Update every"
    static let refreshFooter = "Faster is closer to real time but can hit rate limits."
    static let updatesHeader = "Updates"
    static let autoCheckTitle = "Check for updates automatically"
    static let checkNowButton = "Check now"
    static let githubTitle = AppVersion.githubLabel

    /// "Omelette 2.7.1 (38)": the version label the popover used, plus the build a bug
    /// report needs (2.x's row printed "2.7.1 (38)"). With no build, or no version, the
    /// label alone.
    static func versionTitle(version: String?, build: String?) -> String {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = AppVersion.label(version: version, build: build)
        return version.isEmpty || build.isEmpty ? label : "\(label) (\(build))"
    }

    /// The repository as the link reads it: "adxd-og/usage-checker".
    static var githubLinkText: String {
        String(AppVersion.githubURL.path.drop(while: { $0 == "/" }))
    }
}

/// Settings › General: 2.x General's Startup, Shortcut, Refresh and Updates sections,
/// regrouped as the mockup does.
struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// "Last check" and the check button follow Sparkle through `Updater`'s published copies.
    @ObservedObject private var updater = Updater.shared
    /// OS state (`SMAppService`), not a preference: read when the page is built, so a
    /// reset on Advanced shows here the next time General opens.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    /// The recorder is listening for keys: the row says how to get out.
    @State private var isRecordingShortcut = false

    /// The bundle's version and build, read once.
    private static let versionTitle: String = {
        let info = Bundle.main.infoDictionary
        return GeneralSettingsCopy.versionTitle(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }()

    var body: some View {
        SettingsPage(tab: .general) {
            startup
            refresh
            updates
        }
    }

    private var startup: some View {
        SettingsSection(header: GeneralSettingsCopy.startupHeader) {
            SettingsSwitchRow(
                title: GeneralSettingsCopy.launchAtLoginTitle,
                isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchAtLogin = newValue
                        LaunchAtLogin.isEnabled = newValue
                    }
                )
            )
            SettingsRow(
                title: GeneralSettingsCopy.shortcutTitle,
                caption: GeneralSettingsCopy.shortcutRowCaption(isRecording: isRecordingShortcut)
            ) {
                KeyboardShortcuts.Recorder(for: .peekUsage)
                    .frame(width: GeneralSettingsCopy.shortcutWidth)
                    .accessibilityLabel(GeneralSettingsCopy.shortcutTitle)
            }
            .onReceive(NotificationCenter.default.publisher(for: GeneralSettingsCopy.recorderActivityNotification)) { note in
                isRecordingShortcut = GeneralSettingsCopy.isRecording(note.userInfo)
            }
        }
    }

    private var refresh: some View {
        SettingsSection(header: GeneralSettingsCopy.refreshHeader, footer: GeneralSettingsCopy.refreshFooter) {
            SettingsRow(title: GeneralSettingsCopy.refreshTitle) {
                Picker(GeneralSettingsCopy.refreshTitle, selection: $settings.refreshIntervalSeconds) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                // The poll loop reads the interval only when a sleep cycle ends, so without
                // a restart a 5m → 30s change waited out the old 5 minutes.
                .onChange(of: settings.refreshIntervalSeconds) { _, _ in
                    AppState.shared.restartTimer()
                }
            }
        }
    }

    private var updates: some View {
        SettingsSection(header: GeneralSettingsCopy.updatesHeader) {
            SettingsSwitchRow(
                title: GeneralSettingsCopy.autoCheckTitle,
                isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                )
            )
            SettingsRow(title: Self.versionTitle, caption: Updater.lastCheckText(updater.lastUpdateCheckDate)) {
                Button(GeneralSettingsCopy.checkNowButton) {
                    updater.checkForUpdates()
                }
                .buttonStyle(.settings)
                .disabled(!updater.canCheckForUpdates)
            }
            SettingsRow(title: GeneralSettingsCopy.githubTitle) {
                Button(GeneralSettingsCopy.githubLinkText) {
                    NSWorkspace.shared.open(AppVersion.githubURL)
                }
                .buttonStyle(.omLink)
                .help(AppVersion.githubHelp)
            }
        }
    }
}
