import XCTest
@testable import Omelette

/// Independent verification that P7 lost no 2.x setting (liquid-glass redesign spec
/// § Packages P7: "move sections, no behaviour changes"; § Decisions "Settings
/// (2026-09-25)": "every row maps onto an existing setting"). This is a source scan,
/// not a UI test: it reads the six new tab files under `UsageTracker/UI/Settings/` off
/// disk (the same files `xcodebuild` compiled for this run) and checks each
/// `SettingsStore` key that had a bound control at the merge base (`1e60b42`) is
/// referenced by exactly one of them — the coverage the task brief asks for.
///
/// The full enumeration this file checks against was built independently by reading
/// `git show 1e60b42:UsageTracker/UI/SettingsView.swift`,
/// `…AgentsSettingsView.swift` and `…CommandLineSettingsView.swift` for every
/// `Toggle(`, `Picker(`, `Stepper(`, `TextField(`, `SecureField(` and `Button(`.
final class SettingsCoverageVerificationTests: XCTestCase {
    private func findRepoRoot() throws -> URL {
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<25 {
            candidate = candidate.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
        }
        throw XCTSkip("could not locate the repo root by walking up from the test bundle")
    }

    private let tabFiles = [
        "GeneralSettingsView.swift", "MenuBarSettingsView.swift", "ProvidersSettingsView.swift",
        "NotificationsSettingsView.swift", "IntegrationsSettingsView.swift", "AdvancedSettingsView.swift",
    ]

    /// `[fileName: contents]` for every file under `UsageTracker/UI/Settings/`.
    private func settingsSources() throws -> [String: String] {
        let dir = try findRepoRoot().appendingPathComponent("UsageTracker/UI/Settings")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        var result: [String: String] = [:]
        for name in names {
            result[name] = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        return result
    }

    /// Every `SettingsStore` key that was bound to a `Toggle` / `Picker` / `Stepper` /
    /// `TextField` at the merge base, and the one 3.0 tab file its control moved to
    /// (§ Coverage table in the plan).
    private static let expectedHome: [String: String] = [
        "refreshIntervalSeconds": "GeneralSettingsView.swift",
        "menuBarNumberMode": "MenuBarSettingsView.swift",
        "showsRemaining": "MenuBarSettingsView.swift",
        "codexProviderEnabled": "ProvidersSettingsView.swift",
        "antigravityProviderEnabled": "ProvidersSettingsView.swift",
        "grokProviderEnabled": "ProvidersSettingsView.swift",
        "notificationsEnabled": "NotificationsSettingsView.swift",
        "threshold80": "NotificationsSettingsView.swift",
        "threshold95": "NotificationsSettingsView.swift",
        "paceAlertsEnabled": "NotificationsSettingsView.swift",
        "paceAlertLeadMinutes": "NotificationsSettingsView.swift",
        "resetAlertsEnabled": "NotificationsSettingsView.swift",
        "quietHoursEnabled": "NotificationsSettingsView.swift",
        "quietHoursStart": "NotificationsSettingsView.swift",
        "quietHoursEnd": "NotificationsSettingsView.swift",
        "dailySummaryEnabled": "NotificationsSettingsView.swift",
        "preferAdminWhenAvailable": "AdvancedSettingsView.swift",
        "claudeWeeklyBudgetUSD": "AdvancedSettingsView.swift",
        "anthropicBetaHeader": "AdvancedSettingsView.swift",
        "agentsNotifyNeedsYou": "NotificationsSettingsView.swift",
        "agentsNeedsYouBypassQuietHours": "NotificationsSettingsView.swift",
        "agentsNotifyDone": "NotificationsSettingsView.swift",
        "agentsShowInMenuBar": "MenuBarSettingsView.swift",
        "agentsAnswerPermissions": "IntegrationsSettingsView.swift",
    ]

    /// Every 2.x key that had a bound control is referenced (`.key`) by exactly one
    /// tab file, and it is the file the plan's coverage table names.
    func testEveryTwoPointXBoundKeyLandsInExactlyOneTabFileAndTheRightOne() throws {
        let sources = try settingsSources()
        for (key, expectedFile) in Self.expectedHome {
            let token = ".\(key)"
            let owners = tabFiles.filter { file in
                guard let text = sources[file] else { return false }
                return text.contains(token)
            }
            XCTAssertEqual(owners, [expectedFile], "key '\(key)' should be referenced by exactly \(expectedFile), found: \(owners)")
        }
    }

    /// § Removals: "Force refresh (⌘R does it), Quit (the popover has it)" — neither
    /// button's title text survives anywhere under `UI/Settings/`.
    func testForceRefreshAndQuitButtonsAreGoneFromEveryTabFile() throws {
        let sources = try settingsSources()
        for (file, text) in sources {
            XCTAssertFalse(text.contains("Force refresh now"), "\(file) still has the Force refresh button")
            XCTAssertFalse(text.contains("Quit Omelette"), "\(file) still has the Quit button")
        }
    }

    /// Design Principle 2 / § Settings: "status is a dot + text (no `OMChip`)". No tab
    /// file may construct the tinted-capsule chip the spec drops.
    func testNoTabFileConstructsOMChip() throws {
        let sources = try settingsSources()
        for (file, text) in sources {
            XCTAssertFalse(text.contains("OMChip("), "\(file) constructs OMChip, which § Design drops for Settings")
        }
    }

    /// § Packages P7 / Task 14: the `Settings` scene still hosts `SettingsView()`,
    /// unmodified by the tab split.
    func testTheSettingsSceneStillHostsSettingsView() throws {
        let root = try findRepoRoot()
        let appFile = try String(
            contentsOf: root.appendingPathComponent("UsageTracker/UsageTrackerApp.swift"), encoding: .utf8
        )
        XCTAssertTrue(appFile.contains("Settings {"), "UsageTrackerApp must still declare a Settings scene")
        XCTAssertTrue(appFile.contains("SettingsView()"), "the Settings scene must still host SettingsView()")
    }

    /// D11 / global constraints: P7 may touch only its own files, plus the three named
    /// exceptions. This is a boundary check on the working tree at test time, in
    /// addition to the git-range diff already inspected by hand: `SharedUI/` and
    /// `UsageTrackerWidget/` must build clean with no P7-only symbol leaking into them.
    func testNoNewSettingsTypeLeaksIntoSharedUIOrTheWidgetTarget() throws {
        let root = try findRepoRoot()
        for dir in ["SharedUI", "UsageTrackerWidget"] {
            let url = root.appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { continue }
            for case let relativePath as String in enumerator where relativePath.hasSuffix(".swift") {
                let text = try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
                XCTAssertFalse(text.contains("SettingsTab"), "\(dir)/\(relativePath) references the Settings-only SettingsTab type")
                XCTAssertFalse(text.contains("SettingsSidebar"), "\(dir)/\(relativePath) references the Settings-only SettingsSidebar type")
            }
        }
    }
}
