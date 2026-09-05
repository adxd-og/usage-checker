import SwiftUI

/// Settings → Agents: turn the hooks on and off per source, with the exact text
/// that will be written shown before anything is written, plus the alert
/// toggles and enough diagnostics to tell "not installed" from "installed but
/// nothing is arriving".
struct AgentsSettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @ObservedObject private var sessions = AgentSessionStore.shared

    @State private var claude: HookInstallStatus = .notInstalled
    @State private var codex: HookInstallStatus = .notInstalled
    @State private var claudePreviewShown = false
    @State private var codexPreviewShown = false
    @State private var codexHooks: HookInstallStatus = .notInstalled
    @State private var codexTrust: AgentHooksInstaller.CodexTrustStatus = .awaitingTrust(untrusted: [])
    @State private var codexHooksPreviewShown = false
    @State private var failure: String?
    @State private var received = 0
    @State private var dropped = 0
    @State private var permissionPending = 0
    @State private var permissionAnswered = 0
    @State private var permissionExpired = 0
    @State private var permissionReleased = 0

    private var helperPath: String { AgentPaths.helperSymlinkURL.path }

    var body: some View {
        Form {
            claudeSection
            codexSection
            if let failure {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure).font(OMFont.caption).textSelection(.enabled)
                    }
                }
            }
            alertsSection
            permissionsSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStatus)
        .task { await pollDiagnostics() }
    }

    // MARK: - Sources

    private var claudeSection: some View {
        Section {
            statusRow(claude)
            actionRow(
                status: claude,
                fileURL: AgentPaths.claudeSettingsURL,
                openTitle: "Open settings.json",
                install: { try AgentHooksInstaller.installClaude(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeClaude(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath) }
            )
            preview(
                isExpanded: $claudePreviewShown,
                text: AgentHooksInstaller.claudePreviewJSON(helperPath: helperPath)
            )
            Text("Eight hooks in `~/.claude/settings.json` call Omelette's helper with the session id, the tool name and the folder — never your prompts or file contents. All but the permission hook are `async`, so Claude Code never waits for us. Omelette rewrites the file with sorted keys and two-space indentation and keeps the original as `settings.json.omelette-backup`.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude Code")
        }
    }

    private var codexSection: some View {
        Section {
            Text("Hooks — approvals, tools and turns")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            statusRow(codexHooks)
            actionRow(
                status: codexHooks,
                fileURL: AgentPaths.codexHooksURL,
                openTitle: "Open hooks.json",
                install: { try AgentHooksInstaller.installCodexHooks(hooksURL: AgentPaths.codexHooksURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeCodexHooks(hooksURL: AgentPaths.codexHooksURL, helperPath: helperPath) }
            )
            preview(
                isExpanded: $codexHooksPreviewShown,
                text: AgentHooksInstaller.codexHooksPreviewJSON(helperPath: helperPath)
            )
            if codexHooks != .notInstalled {
                let trust = AgentsSettingsText.codexTrustLine(codexTrust)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: trust.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    Text(trust.text).textSelection(.enabled)
                }
                .font(OMFont.caption)
                .foregroundStyle(trust.isTrusted ? Color.green : Color.orange)
            }
            Text("Seven hooks in `~/.codex/hooks.json` — the same helper, the same fields and the same Allow / Deny as Claude Code's. Codex runs a hook only after you trust it once: type `/hooks` inside Codex.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Notify — finished turns")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            statusRow(codex)
            actionRow(
                status: codex,
                fileURL: AgentPaths.codexConfigURL,
                openTitle: "Open config.toml",
                install: { try AgentHooksInstaller.installCodex(configURL: AgentPaths.codexConfigURL, helperPath: helperPath) },
                remove: { try AgentHooksInstaller.removeCodex(configURL: AgentPaths.codexConfigURL, helperPath: helperPath) }
            )
            preview(
                isExpanded: $codexPreviewShown,
                text: AgentHooksInstaller.codexNotifyLine(helperPath: helperPath)
            )
            if case .conflict(let line) = codex {
                VStack(alignment: .leading, spacing: 4) {
                    Text("`config.toml` already has a `notify` of its own:")
                        .font(OMFont.caption).foregroundStyle(.secondary)
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Omelette's line") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(AgentHooksInstaller.codexNotifyLine(helperPath: helperPath), forType: .string)
                    }
                    .buttonStyle(.link)
                }
            }
            Text("`notify` reports a finished turn, which the hooks do not cover. The line goes above the first `[table]` so it stays a top-level key.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Codex")
        }
    }

    private func statusRow(_ status: HookInstallStatus) -> some View {
        HStack(spacing: OMSpacing.s) {
            OMChip(text: label(status), tint: tint(status))
            Spacer()
        }
    }

    @ViewBuilder
    private func actionRow(
        status: HookInstallStatus,
        fileURL: URL,
        openTitle: String,
        install: @escaping () throws -> Void,
        remove: @escaping () throws -> Void
    ) -> some View {
        HStack {
            switch status {
            case .notInstalled:
                Button("Enable") { run(install) }
            case .outdated:
                Button("Update") { run(install) }
                Button("Disable") { run(remove) }
            case .installed:
                Button("Disable") { run(remove) }
            case .conflict:
                Button("Enable") {}.disabled(true)
            }
            Spacer()
            Button(openTitle) { NSWorkspace.shared.open(fileURL) }
                .disabled(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    private func preview(isExpanded: Binding<Bool>, text: String) -> some View {
        DisclosureGroup("What will be written", isExpanded: isExpanded) {
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
        }
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        Section("Alerts") {
            Toggle("Notify when an agent needs you", isOn: $settings.agentsNotifyNeedsYou)
            if settings.agentsNotifyNeedsYou {
                Toggle("Even during quiet hours", isOn: $settings.agentsNeedsYouBypassQuietHours)
            }
            Toggle("Notify when an agent finishes a turn", isOn: $settings.agentsNotifyDone)
            Toggle("Show agents in the menu bar", isOn: $settings.agentsShowInMenuBar)
            Text("\"Needs you\" fires when a session stops for a permission decision — that one ignores quiet hours by default, because an agent that waits all night has wasted the night. Finished-turn alerts fire on every reply, so they start off.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            Toggle("Answer permission requests from Omelette", isOn: $settings.agentsAnswerPermissions)
            Text("Allow / Deny appear on the notification and in the popover only while the terminal running that session isn't in front; otherwise Claude Code or Codex asks in the terminal as usual. A request you don't answer goes back to the terminal after two minutes.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            if let caption = AgentsSettingsText.permissionsInactiveCaption(
                claude: claude, codexHooks: codexHooks, codexTrust: codexTrust
            ) {
                // `PermissionBroker.featureIsUsable` holds nothing unless one agent's
                // hooks match this build's template (the 150 s PermissionRequest cap);
                // a 2.1 install reads "older than this build" above and needs one
                // Update, and a Codex hook needs its one-time trust.
                Text(caption)
                    .font(OMFont.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Pending", value: "\(permissionPending)")
            LabeledContent("Answered", value: "\(permissionAnswered)")
            LabeledContent("Expired", value: "\(permissionExpired)")
            LabeledContent("Released to terminal", value: "\(permissionReleased)")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Socket") {
                Text(AgentPaths.socketURL.path)
                    .font(OMFont.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            LabeledContent("Helper", value: "omelette-hook v\(AgentPaths.helperVersion)")
            if let startError = AgentChannel.shared.startError {
                LabeledContent("Socket status") {
                    Text(startError).font(OMFont.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            LabeledContent("Events", value: "\(received) received · \(dropped) dropped")
            LabeledContent("Last event", value: lastEventText)
            Text("Received counts messages the helper delivered; dropped counts messages the socket could not decode. Zero received with hooks installed usually means Omelette was restarted after the last session started — the next prompt re-registers it.")
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lastEventText: String {
        guard let date = sessions.lastEventAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// The counters live on plain objects, not on an ObservableObject, so the tab
    /// re-reads them while it is on screen. `.task` cancels this when it is not.
    /// The install status is re-read on the same tick — two small file reads — so
    /// editing settings.json in another window updates the line here.
    private func pollDiagnostics() async {
        while !Task.isCancelled {
            received = AgentDiagnostics.server?.receivedCount ?? 0
            dropped = AgentDiagnostics.server?.droppedCount ?? 0
            let broker = PermissionBroker.shared
            permissionPending = broker.pending.count
            permissionAnswered = broker.answeredCount
            permissionExpired = broker.expiredCount
            permissionReleased = broker.releasedForPresenceCount
            refreshStatus()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Actions

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch {
            failure = describe(error)
        }
        refreshStatus()
    }

    private func refreshStatus() {
        claude = AgentHooksInstaller.claudeStatus(settingsURL: AgentPaths.claudeSettingsURL, helperPath: helperPath)
        codex = AgentHooksInstaller.codexStatus(configURL: AgentPaths.codexConfigURL, helperPath: helperPath)
        codexHooks = AgentHooksInstaller.codexHooksStatus(hooksURL: AgentPaths.codexHooksURL, helperPath: helperPath)
        codexTrust = AgentHooksInstaller.codexTrust(configURL: AgentPaths.codexConfigURL, hooksURL: AgentPaths.codexHooksURL)
    }

    private func describe(_ error: Swift.Error) -> String {
        guard let installerError = error as? AgentHooksInstaller.Error else {
            return error.localizedDescription
        }
        switch installerError {
        case .unparsable(let url):
            return "\(url.lastPathComponent) isn't valid — Omelette won't overwrite a file it can't read. Fix or move it and try again."
        case .conflict(let line):
            return "Another tool already owns that setting: \(line)"
        }
    }

    private func label(_ status: HookInstallStatus) -> String { AgentsSettingsText.hookStatusLabel(status) }

    private func tint(_ status: HookInstallStatus) -> Color { AgentsSettingsText.hookStatusTint(status) }
}

#if DEBUG
// Shows the real install status of this machine's hooks — which is what the tab
// is for. The 2 s diagnostics poll keeps running while the canvas is open.
#Preview("Agents settings — light") {
    AgentsSettingsView()
        .frame(width: 520, height: 540)
}

#Preview("Agents settings — dark") {
    AgentsSettingsView()
        .frame(width: 520, height: 540)
        .preferredColorScheme(.dark)
}
#endif
