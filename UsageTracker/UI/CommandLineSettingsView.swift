import SwiftUI

/// Settings → General → Command line: where the `omelette` tool is, how to put it on
/// your PATH, and the one-click Claude Code status line.
///
/// A `Group` of `Section`s rather than a tab of its own: it belongs beside the other
/// General settings, and three sections is not a tab's worth of anything.
struct CommandLineSettingsView: View {
    @State private var statusLine: HookInstallStatus = .notInstalled
    @State private var statusLinePreviewShown = false
    @State private var failure: String?
    @State private var copied = false

    private var cliPath: String { AgentPaths.cliSymlinkURL.path }

    var body: some View {
        Group {
            toolSection
            statusLineSection
            if let failure {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure).font(OMFont.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear(perform: refreshStatus)
    }

    // MARK: - The tool

    private var toolSection: some View {
        Section {
            LabeledContent("Command") {
                Text(cliPath)
                    .font(OMFont.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack {
                Button(copied ? "Copied" : "Copy PATH line") {
                    copy(CommandLineSettingsText.pathExportLine)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AgentPaths.cliSymlinkURL])
                }
                .disabled(!FileManager.default.fileExists(atPath: cliPath))
            }
            Text(CommandLineSettingsText.pathExportLine)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(CommandLineSettingsText.pathCaption)
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Command line")
        }
    }

    // MARK: - Claude Code status line

    private var statusLineSection: some View {
        Section {
            HStack(spacing: OMSpacing.s) {
                OMChip(
                    text: AgentsSettingsText.hookStatusLabel(statusLine),
                    tint: AgentsSettingsText.hookStatusTint(statusLine)
                )
                Spacer()
            }
            HStack {
                switch statusLine {
                case .notInstalled:
                    Button("Enable") { run { try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cliPath) } }
                case .outdated:
                    Button("Update") { run { try StatusLineInstaller.install(settingsURL: settingsURL, cliPath: cliPath) } }
                    Button("Disable") { run { try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cliPath) } }
                case .installed:
                    Button("Disable") { run { try StatusLineInstaller.remove(settingsURL: settingsURL, cliPath: cliPath) } }
                case .conflict:
                    Button("Enable") {}.disabled(true)
                }
                Spacer()
                Button("Open settings.json") { NSWorkspace.shared.open(settingsURL) }
                    .disabled(!FileManager.default.fileExists(atPath: settingsURL.path))
            }
            DisclosureGroup(CommandLineSettingsText.statusLinePreviewTitle, isExpanded: $statusLinePreviewShown) {
                ScrollView {
                    Text(StatusLineInstaller.previewJSON(cliPath: cliPath))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            if case .conflict(let command) = statusLine {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CommandLineSettingsText.conflictCaption(command))
                        .font(OMFont.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Copy Omelette's command") {
                        copy(StatusLineInstaller.command(cliPath: cliPath))
                    }
                    .buttonStyle(.link)
                }
            }
            Text(CommandLineSettingsText.statusLineCaption)
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Claude Code status line")
        }
    }

    // MARK: - Actions

    private var settingsURL: URL { AgentPaths.claudeSettingsURL }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        // Confirmation, not a state: put the button's own name back after a beat.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch let error as SettingsFile.Error {
            switch error {
            case .unparsable(let url):
                failure = "\(url.lastPathComponent) isn't valid — Omelette won't overwrite a file it can't read. Fix or move it and try again."
            case .conflict(let line):
                failure = "Another tool already owns that setting: \(line)"
            }
        } catch {
            failure = error.localizedDescription
        }
        refreshStatus()
    }

    private func refreshStatus() {
        statusLine = StatusLineInstaller.status(settingsURL: settingsURL, cliPath: cliPath)
    }
}

#if DEBUG
// Shows this machine's real status.json path and the real state of its settings.json,
// which is what the section is for.
#Preview("Command line settings — light") {
    Form { CommandLineSettingsView() }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
}

#Preview("Command line settings — dark") {
    Form { CommandLineSettingsView() }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
        .preferredColorScheme(.dark)
}
#endif
