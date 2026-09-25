import SwiftUI

/// Settings › Integrations' words and rules (`Settings-Integrations(-Light).dc.html`).
/// The 2.x text rules stay the source of the status words, the buttons and the long
/// captions; the mockup's one-line captions are new here, and the long ones are hover
/// help.
enum IntegrationsSettingsCopy {
    static let claudeHeader = "Claude Code"
    static let codexHeader = "Codex"
    static let hooksTitle = "Hooks"
    static let statusLineTitle = "Status line"
    static let mcpTitle = "MCP server"
    static let codexNotifyTitle = "Notify for finished turns"

    static let claudeHooksCaption = "Session id, tool name and folder only, never prompts or files."
    static let statusLineCaption = "Session window, reset time, today's cost in Claude Code's status bar."
    static let claudeMCPCaption = "Read-only: get_usage, get_agents, get_sessions."
    static let codexHooksCaption = "Trust once with /hooks inside Codex."

    static let claudeHooksHelp = "Eight hooks in ~/.claude/settings.json call Omelette's helper with the session id, the tool name and the folder — never your prompts or file contents. All but the permission hook are async, so Claude Code never waits for us. Omelette rewrites the file with sorted keys and two-space indentation and keeps the original as settings.json.omelette-backup."
    static let codexHooksHelp = "Seven hooks in ~/.codex/hooks.json — the same helper, the same fields and the same Allow / Deny as Claude Code's. Codex runs a hook only after you trust it once: type /hooks inside Codex."
    static let codexNotifyHelp = "notify reports a finished turn, which the hooks do not cover. The line goes above the first [table] in ~/.codex/config.toml so it stays a top-level key."
    static var statusLineHelp: String { CommandLineSettingsText.statusLineCaption }
    static var claudeMCPHelp: String { CommandLineSettingsText.mcpCaption + "\n\n" + CommandLineSettingsText.mcpClaudeCaption }
    static var codexMCPHelp: String { CommandLineSettingsText.mcpCodexCaption }

    static let permissionsHeader = "Permissions"
    static let permissionsTitle = "Answer permission requests from Omelette"
    static let permissionsCaption = "Allow / Deny show only while that terminal isn't in front. Unanswered requests go back after 2 minutes."
    static let permissionsHelp = "Allow / Deny appear on the notification and in the popover only while the terminal running that session isn't in front; otherwise Claude Code or Codex asks in the terminal as usual. A request you don't answer goes back to the terminal after two minutes."

    static let commandLineHeader = "Command line"
    static let commandTitle = AgentPaths.cliName
    static let copyPathButton = "Copy PATH line"
    static let copiedButton = "Copied"
    static let revealButton = "Reveal in Finder"
    static let commandLineFooter = "Add the PATH line to ~/.zshrc, then omelette status works from any terminal."
    static var commandHelp: String { CommandLineSettingsText.pathCaption }

    static let copyStatusLineCommand = "Copy Omelette's command"
    static let copyCodexNotifyLine = "Copy Omelette's line"
    /// The installer row's context-menu item that copies the exact text Enable would
    /// write: 2.x's "What will be written" disclosure, one right-click away.
    static var copyPreviewTitle: String {
        "Copy " + CommandLineSettingsText.statusLinePreviewTitle.lowercased()
    }

    /// An installer's state as a dot and 2.x's words.
    static func installStatus(_ status: HookInstallStatus) -> SettingsStatus {
        SettingsStatus(text: AgentsSettingsText.hookStatusLabel(status), dot: AgentsSettingsText.hookStatusDot(status))
    }

    /// The amber line under Codex › Hooks while Codex still ignores some of them. Codex
    /// refuses a hook it has not been told to trust and says nothing, so the row says it.
    static func codexTrustNote(hooks: HookInstallStatus, trust: AgentHooksInstaller.CodexTrustStatus) -> SettingsCaption? {
        guard hooks != .notInstalled else { return nil }
        let line = AgentsSettingsText.codexTrustLine(trust)
        return line.isTrusted ? nil : SettingsCaption(text: line.text, token: .warning)
    }

    /// Why Allow / Deny is doing nothing, from the broker's own truth table.
    static func permissionsNote(
        claude: HookInstallStatus,
        codexHooks: HookInstallStatus,
        codexTrust: AgentHooksInstaller.CodexTrustStatus
    ) -> SettingsCaption? {
        AgentsSettingsText.permissionsInactiveCaption(claude: claude, codexHooks: codexHooks, codexTrust: codexTrust)
            .map { SettingsCaption(text: $0, token: .warning) }
    }

    /// Someone else's status line, quoted so the user can decide; Omelette never overwrites it.
    static func statusLineConflictNote(_ status: HookInstallStatus) -> SettingsCaption? {
        guard case .conflict(let command) = status else { return nil }
        return SettingsCaption(text: CommandLineSettingsText.conflictCaption(command), token: .secondary)
    }

    /// Someone else's `notify` in config.toml, quoted.
    static func codexNotifyConflictNote(_ status: HookInstallStatus) -> SettingsCaption? {
        guard case .conflict(let line) = status else { return nil }
        return SettingsCaption(text: "config.toml already has a notify of its own:\n\(line)", token: .secondary)
    }

    /// Only a conflict offers to copy Omelette's own line.
    static func isConflict(_ status: HookInstallStatus) -> Bool {
        if case .conflict = status { return true }
        return false
    }

    /// What an Enable, Update or Disable that failed says.
    static func failure(_ error: Error) -> String {
        guard let error = error as? SettingsFile.Error else { return error.localizedDescription }
        switch error {
        case .unparsable(let url):
            return "\(url.lastPathComponent) isn't valid — Omelette won't overwrite a file it can't read. Fix or move it and try again."
        case .conflict(let line):
            return "Another tool already owns that setting: \(line)"
        }
    }

    /// The installer row's context-menu item (2.x's "Open settings.json" button).
    static func openFileTitle(_ url: URL) -> String {
        "Open \(url.lastPathComponent)"
    }
}

/// Settings › Integrations: 2.x Agents' hooks and permissions, and 2.x General's command
/// line, status line and MCP sections, grouped by agent.
struct IntegrationsSettingsView: View {
    /// The six installer rows, so a failure shows under the row whose action failed.
    private enum Installer: Hashable {
        case claudeHooks, statusLine, claudeMCP, codexHooks, codexNotify, codexMCP
    }

    /// What the last Enable / Update / Disable could not do, and on which row.
    private struct InstallerFailure: Equatable {
        let installer: Installer
        let message: String
    }

    @ObservedObject private var settings = SettingsStore.shared

    @State private var claudeHooks: HookInstallStatus = .notInstalled
    @State private var statusLine: HookInstallStatus = .notInstalled
    @State private var claudeMCP: HookInstallStatus = .notInstalled
    @State private var codexHooks: HookInstallStatus = .notInstalled
    @State private var codexNotify: HookInstallStatus = .notInstalled
    @State private var codexMCP: HookInstallStatus = .notInstalled
    @State private var codexTrust: AgentHooksInstaller.CodexTrustStatus = .awaitingTrust(untrusted: [])
    @State private var failure: InstallerFailure?
    @State private var copied = false

    private var helperPath: String { AgentPaths.helperSymlinkURL.path }
    private var cliPath: String { AgentPaths.cliSymlinkURL.path }

    var body: some View {
        SettingsPage(tab: .integrations) {
            claudeSection
            codexSection
            permissionsSection
            commandLineSection
        }
        .onAppear(perform: refreshAllStatus)
        // The hook files are re-read every 2 s while the page is up, as 2.x's Agents tab
        // did, so an edit in another window shows here. The MCP entries live in
        // ~/.claude.json, which can run to megabytes: read on appear and after an action
        // only, as 2.x's General did.
        .task {
            while !Task.isCancelled {
                refreshHookStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Sections

    private var claudeSection: some View {
        SettingsSection(header: IntegrationsSettingsCopy.claudeHeader) {
            installerRow(
                id: .claudeHooks,
                title: IntegrationsSettingsCopy.hooksTitle,
                caption: IntegrationsSettingsCopy.claudeHooksCaption,
                help: IntegrationsSettingsCopy.claudeHooksHelp,
                status: claudeHooks,
                fileURL: AgentPaths.claudeSettingsURL,
                preview: { AgentHooksInstaller.claudePreviewJSON(helperPath: helperPath) },
                install: { try AgentHooksInstaller.installClaude(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeClaude(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath) }
            )
            installerRow(
                id: .statusLine,
                title: IntegrationsSettingsCopy.statusLineTitle,
                caption: IntegrationsSettingsCopy.statusLineCaption,
                help: IntegrationsSettingsCopy.statusLineHelp,
                status: statusLine,
                fileURL: AgentPaths.claudeSettingsURL,
                note: IntegrationsSettingsCopy.statusLineConflictNote(statusLine),
                noteAction: IntegrationsSettingsCopy.isConflict(statusLine)
                    ? SettingsLinkAction(title: IntegrationsSettingsCopy.copyStatusLineCommand) {
                        copyToPasteboard(StatusLineInstaller.command(cliPath: cliPath))
                    }
                    : nil,
                preview: { StatusLineInstaller.previewJSON(cliPath: cliPath) },
                install: { try StatusLineInstaller.install(settingsURL: AgentPaths.claudeSettingsURL, cliPath: cliPath) },
                remove: { try StatusLineInstaller.remove(settingsURL: AgentPaths.claudeSettingsURL, cliPath: cliPath) }
            )
            installerRow(
                id: .claudeMCP,
                title: IntegrationsSettingsCopy.mcpTitle,
                caption: IntegrationsSettingsCopy.claudeMCPCaption,
                help: IntegrationsSettingsCopy.claudeMCPHelp,
                status: claudeMCP,
                fileURL: AgentPaths.claudeConfigURL,
                preview: { MCPInstaller.claudePreviewJSON(cliPath: cliPath) },
                install: { try MCPInstaller.installClaude(configURL: AgentPaths.claudeConfigURL, cliPath: cliPath) },
                remove: { try MCPInstaller.removeClaude(configURL: AgentPaths.claudeConfigURL, cliPath: cliPath) }
            )
        }
    }

    private var codexSection: some View {
        SettingsSection(header: IntegrationsSettingsCopy.codexHeader) {
            installerRow(
                id: .codexHooks,
                title: IntegrationsSettingsCopy.hooksTitle,
                caption: IntegrationsSettingsCopy.codexHooksCaption,
                help: IntegrationsSettingsCopy.codexHooksHelp,
                status: codexHooks,
                fileURL: AgentPaths.codexHooksURL,
                note: IntegrationsSettingsCopy.codexTrustNote(hooks: codexHooks, trust: codexTrust),
                preview: { AgentHooksInstaller.codexHooksPreviewJSON(helperPath: helperPath) },
                install: { try AgentHooksInstaller.installCodexHooks(hooksURL: AgentPaths.codexHooksURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeCodexHooks(hooksURL: AgentPaths.codexHooksURL, helperPath: helperPath) }
            )
            installerRow(
                id: .codexNotify,
                title: IntegrationsSettingsCopy.codexNotifyTitle,
                caption: nil,
                help: IntegrationsSettingsCopy.codexNotifyHelp,
                status: codexNotify,
                fileURL: AgentPaths.codexConfigURL,
                note: IntegrationsSettingsCopy.codexNotifyConflictNote(codexNotify),
                noteAction: IntegrationsSettingsCopy.isConflict(codexNotify)
                    ? SettingsLinkAction(title: IntegrationsSettingsCopy.copyCodexNotifyLine) {
                        copyToPasteboard(AgentHooksInstaller.codexNotifyLine(helperPath: helperPath))
                    }
                    : nil,
                preview: { AgentHooksInstaller.codexNotifyLine(helperPath: helperPath) },
                install: { try AgentHooksInstaller.installCodex(configURL: AgentPaths.codexConfigURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeCodex(configURL: AgentPaths.codexConfigURL, helperPath: helperPath) }
            )
            installerRow(
                id: .codexMCP,
                title: IntegrationsSettingsCopy.mcpTitle,
                caption: nil,
                help: IntegrationsSettingsCopy.codexMCPHelp,
                status: codexMCP,
                fileURL: AgentPaths.codexConfigURL,
                preview: { MCPInstaller.codexPreview(cliPath: cliPath) },
                install: { try MCPInstaller.installCodex(configURL: AgentPaths.codexConfigURL, cliPath: cliPath) },
                remove: { try MCPInstaller.removeCodex(configURL: AgentPaths.codexConfigURL, cliPath: cliPath) }
            )
        }
    }

    private var permissionsSection: some View {
        SettingsSection(header: IntegrationsSettingsCopy.permissionsHeader) {
            SettingsRow(
                title: IntegrationsSettingsCopy.permissionsTitle,
                caption: IntegrationsSettingsCopy.permissionsCaption,
                // `PermissionBroker.featureIsUsable` holds nothing unless one agent's hooks
                // match this build's template; a 2.1 install needs one Update, and a Codex
                // hook its one-time trust.
                note: IntegrationsSettingsCopy.permissionsNote(
                    claude: claudeHooks, codexHooks: codexHooks, codexTrust: codexTrust
                ),
                help: IntegrationsSettingsCopy.permissionsHelp
            ) {
                SettingsSwitch(label: IntegrationsSettingsCopy.permissionsTitle, isOn: $settings.agentsAnswerPermissions)
            }
        }
    }

    private var commandLineSection: some View {
        SettingsSection(
            header: IntegrationsSettingsCopy.commandLineHeader,
            footer: IntegrationsSettingsCopy.commandLineFooter
        ) {
            SettingsRow(
                title: IntegrationsSettingsCopy.commandTitle,
                caption: SettingsCopy.tildePath(
                    AgentPaths.binURL.path, home: FileManager.default.homeDirectoryForCurrentUser.path
                ),
                help: IntegrationsSettingsCopy.commandHelp
            ) {
                Button(copied ? IntegrationsSettingsCopy.copiedButton : IntegrationsSettingsCopy.copyPathButton) {
                    copyPathLine()
                }
                .buttonStyle(.settings)
                .help(CommandLineSettingsText.pathExportLine)
                Button(IntegrationsSettingsCopy.revealButton) {
                    NSWorkspace.shared.activateFileViewerSelecting([AgentPaths.cliSymlinkURL])
                }
                .buttonStyle(.settings)
                .disabled(!FileManager.default.fileExists(atPath: cliPath))
            }
        }
    }

    // MARK: - Rows

    /// One installer: its state as a dot and words, then Enable / Update / Disable as 2.x
    /// decided them (`CommandLineSettingsText`). If its last action failed, the message
    /// wraps in full under the row (2.x's words, `IntegrationsSettingsCopy.failure`). The
    /// row's context menu opens the file it writes and copies what Enable would write there
    /// (`preview`, built only on click).
    private func installerRow(
        id: Installer,
        title: String,
        caption: String?,
        help: String,
        status: HookInstallStatus,
        fileURL: URL,
        note: SettingsCaption? = nil,
        noteAction: SettingsLinkAction? = nil,
        preview: @escaping () -> String,
        install: @escaping () throws -> Void,
        remove: @escaping () throws -> Void
    ) -> some View {
        SettingsRow(
            title: title,
            caption: caption,
            note: note,
            noteAction: noteAction,
            error: failure?.installer == id ? failure?.message : nil,
            help: help
        ) {
            SettingsStatusLabel(status: IntegrationsSettingsCopy.installStatus(status))
            if let installTitle = CommandLineSettingsText.installButtonTitle(status) {
                Button(installTitle) { run(install, on: id) }
                    .buttonStyle(.settings)
                    .disabled(!CommandLineSettingsText.installButtonIsEnabled(status))
            }
            if CommandLineSettingsText.showsDisableButton(status) {
                Button(CommandLineSettingsText.disableButtonTitle) { run(remove, on: id) }
                    .buttonStyle(.settings)
            }
        }
        .contextMenu {
            Button(IntegrationsSettingsCopy.openFileTitle(fileURL)) {
                NSWorkspace.shared.open(fileURL)
            }
            .disabled(!FileManager.default.fileExists(atPath: fileURL.path))
            Button(IntegrationsSettingsCopy.copyPreviewTitle) {
                copyToPasteboard(preview())
            }
        }
    }

    // MARK: - Actions

    /// Runs an installer action. A success clears any failure on the page, as 2.x did;
    /// a failure is kept with the row it happened on.
    private func run(_ action: () throws -> Void, on installer: Installer) {
        do {
            try action()
            failure = nil
        } catch {
            failure = InstallerFailure(installer: installer, message: IntegrationsSettingsCopy.failure(error))
        }
        refreshAllStatus()
    }

    private func copyPathLine() {
        copyToPasteboard(CommandLineSettingsText.pathExportLine)
        copied = true
        // Confirmation, not a state: the button's own name comes back after a beat.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The small files the hooks live in: Claude's settings.json, Codex's config.toml and
    /// hooks.json.
    private func refreshHookStatus() {
        claudeHooks = AgentHooksInstaller.claudeStatus(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath)
        codexNotify = AgentHooksInstaller.codexStatus(configURL: AgentPaths.codexConfigURL, helperPath: helperPath)
        codexHooks = AgentHooksInstaller.codexHooksStatus(hooksURL: AgentPaths.codexHooksURL, helperPath: helperPath)
        codexTrust = AgentHooksInstaller.codexTrust(configURL: AgentPaths.codexConfigURL, hooksURL: AgentPaths.codexHooksURL)
    }

    private func refreshAllStatus() {
        refreshHookStatus()
        statusLine = StatusLineInstaller.status(settingsURL: AgentPaths.claudeSettingsURL, cliPath: cliPath)
        claudeMCP = MCPInstaller.claudeStatus(configURL: AgentPaths.claudeConfigURL, cliPath: cliPath)
        codexMCP = MCPInstaller.codexStatus(configURL: AgentPaths.codexConfigURL, cliPath: cliPath)
    }
}

#if DEBUG
// A long failure must stay whole at the width a 780 pt window gives the page: 780 − 2 × 10
// inset − 196 sidebar − 30 − 28 gutters = 506 pt. The real app cannot be made to fail
// without breaking a config file the owner uses, so this injects two real messages: the
// system's refusal to write a file, and 2.x's "isn't valid" recovery sentence.
#Preview("Integrations — long failure") {
    let pageWidth = SettingsWindowLayout.width - 2 * SettingsWindowLayout.windowInset
        - SettingsSidebarRules.width - SettingsWindowLayout.columnLeading - SettingsWindowLayout.columnTrailing
    let refused = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/tester/.codex/hooks.json"])
    let unreadable = SettingsFile.Error.unparsable(URL(fileURLWithPath: "/Users/tester/.codex/config.toml"))
    SettingsSection(header: IntegrationsSettingsCopy.codexHeader) {
        SettingsRow(
            title: IntegrationsSettingsCopy.hooksTitle,
            caption: IntegrationsSettingsCopy.codexHooksCaption,
            error: IntegrationsSettingsCopy.failure(refused)
        ) {
            SettingsStatusLabel(status: IntegrationsSettingsCopy.installStatus(.notInstalled))
            Button(CommandLineSettingsText.installButtonTitle(.notInstalled) ?? "") {}
                .buttonStyle(.settings)
        }
        SettingsRow(
            title: IntegrationsSettingsCopy.mcpTitle,
            error: IntegrationsSettingsCopy.failure(unreadable)
        ) {
            SettingsStatusLabel(status: IntegrationsSettingsCopy.installStatus(.installed))
            Button(CommandLineSettingsText.disableButtonTitle) {}
                .buttonStyle(.settings)
        }
    }
    .frame(width: pageWidth)
    .padding()
}
#endif
