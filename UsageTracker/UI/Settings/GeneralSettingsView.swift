import SwiftUI

/// Settings › General's words (`Settings-General(-Light).dc.html`).
enum GeneralSettingsCopy {
    static let startupHeader = "Startup"
    static let launchAtLoginTitle = "Launch at login"
    static let menuBarIconHeader = "Menu bar icon"
    /// Spec 2026-11-03 § P4.
    static let virtualNotchTitle = "Island on displays without a notch"
    static let virtualNotchCaption = "A black pill in the middle of the menu bar opens Brioche. Off: the menu bar icon opens it there, as before 4.1; with a notched display attached, turn on Show in menu bar."
    static let showInMenuBarTitle = "Show in menu bar"
    static let refreshHeader = "Refresh"
    static let refreshTitle = "Update every"
    static let refreshFooter = "Faster is closer to real time but can hit rate limits."
    static let updatesHeader = "Updates"
    static let autoCheckTitle = "Check for updates automatically"
    static let checkNowButton = "Check now"
    static let githubTitle = AppVersion.githubLabel
    static let keepAwakeHeader = "Keep awake"
    static let keepAwakeFloorTitle = "End below \(KeepAwakeRules.batteryFloorPercent) % on battery"
    static let keepAwakeFooter = "Keep awake with the lid closed ends on time even when Brioche is not running, and never resumes after a restart."

    /// "Brioche 2.7.1 (38)": the version label the popover used, plus the build a bug
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

/// Settings › General: 2.x General's Startup, Refresh and Updates sections, regrouped
/// as the mockup does. 2.x's popover shortcut is gone (owner's decision, 2026-09-26).
struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// "Last check" and the check button follow Sparkle through `Updater`'s published copies.
    @ObservedObject private var updater = Updater.shared
    /// OS state (`SMAppService`), not a preference: read when the page is built, so a
    /// reset on Advanced shows here the next time General opens.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    /// Whether a display shows the island, a notch or a virtual one: Show in menu bar's value,
    /// whether it moves, and its caption follow it (notch-island spec 2026-10-29 § 3.7; spec
    /// 2026-11-03 § Status item). Read for the first frame, so a Mac with no island display never
    /// flashes the switch as off and movable, and again whenever the displays change or Island on
    /// displays without a notch is flipped (§ P4).
    @State private var islandDisplayAttached = StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.current())

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
            menuBarIcon
            refresh
            keepAwake
            updates
        }
        .onAppear { readDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            readDisplays()
        }
        // After the value has landed: the reading reads the store.
        .onChange(of: settings.virtualNotchEnabled) { _, _ in readDisplays() }
    }

    private func readDisplays() {
        islandDisplayAttached = StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.current())
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
        }
    }

    /// Island on displays without a notch (spec 2026-11-03 § P4), then Show in menu bar (§ 3.7, D4; spec
    /// 2026-11-03): off by default while a display shows the island, on and held while none is (ruling
    /// R15). `IslandController` re-places the pills and `StatusBarController` adds or removes the item at once.
    private var menuBarIcon: some View {
        SettingsSection(header: GeneralSettingsCopy.menuBarIconHeader) {
            SettingsSwitchRow(
                title: GeneralSettingsCopy.virtualNotchTitle,
                caption: GeneralSettingsCopy.virtualNotchCaption,
                isOn: $settings.virtualNotchEnabled
            )
            SettingsSwitchRow(
                title: GeneralSettingsCopy.showInMenuBarTitle,
                caption: StatusItemVisibilityRules.caption(islandDisplayAttached: islandDisplayAttached),
                isOn: Binding(
                    get: {
                        StatusItemVisibilityRules.isShown(
                            setting: settings.showInMenuBar,
                            islandDisplayAttached: islandDisplayAttached
                        )
                    },
                    set: { settings.showInMenuBar = $0 }
                )
            )
            .disabled(!StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: islandDisplayAttached))
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

    /// Spec 2026-10-26 § UI. The switch is a preference read at every Apply, and an armed
    /// helper hears a change at once (§ Behaviour, floor switch while armed).
    private var keepAwake: some View {
        SettingsSection(header: GeneralSettingsCopy.keepAwakeHeader, footer: GeneralSettingsCopy.keepAwakeFooter) {
            SettingsSwitchRow(
                title: GeneralSettingsCopy.keepAwakeFloorTitle,
                isOn: Binding(
                    get: { settings.keepAwakeFloorEnabled },
                    set: { newValue in
                        settings.keepAwakeFloorEnabled = newValue
                        Task { await KeepAwakeModel.shared.floorChanged(newValue) }
                    }
                )
            )
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
