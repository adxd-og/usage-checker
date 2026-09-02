import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var dashboard = DashboardState.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// Persisted tab selection (a service id, or `WindowRanking.allTab`).
    /// Self-heals: a stored provider that isn't currently displayed (toggled
    /// off, signed out of the list, first launch) resolves back to All, and the
    /// stored value stays put until the user picks again.
    @AppStorage("selectedProviderTab") private var selectedProviderTab: String = WindowRanking.allTab

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            header
            if state.snapshot.isStale && state.snapshot.hasAnyData { staleNotice }
            if showsSegments { segments }
            content
            footer
        }
        .padding(OMSpacing.l)
        .frame(width: 360)
    }

    // MARK: - Tab state

    private var displayedServices: [ServiceSnapshot] { state.snapshot.services }

    private var showsSegments: Bool { displayedServices.count > 1 }

    /// With a single service there is no segmented control, so that service's
    /// tab is the only thing to show; with several, the stored value decides
    /// and an id that isn't on screen falls back to All.
    private var currentTab: String {
        showsSegments
            ? WindowRanking.resolveTab(stored: selectedProviderTab, displayed: displayedServices)
            : (displayedServices.first?.id ?? WindowRanking.allTab)
    }

    /// nil on the All tab.
    private var selectedService: ServiceSnapshot? {
        displayedServices.first { $0.id == currentTab }
    }

    private var segments: some View {
        OMSegmentedControl(
            items: [OMSegmentItem(id: WindowRanking.allTab, title: "All")]
                + displayedServices.map {
                    OMSegmentItem(id: $0.id, title: $0.displayName, serviceID: $0.id, sfFallback: $0.icon)
                },
            selection: Binding(
                get: { currentTab },
                set: { selectedProviderTab = $0 }
            )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            // The real app icon, not a drawn stand-in — matches the welcome
            // tour and tracks icon updates for free.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Omelette")
                    .font(OMFont.title)
                // Only the relative "Updated Xs ago" text needs a clock tick —
                // keep the periodic timeline off the rest of the header.
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    Text(metaLine(now: ctx.date))
                }
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metaLine(now: Date) -> String {
        let updated = updatedText(now: now)
        if let plan = selectedService?.plan { return "\(plan) · \(updated)" }
        return updated
    }

    private func updatedText(now: Date) -> String {
        let t = state.snapshot.fetchedAt.timeIntervalSince1970
        if t < 1 { return "Never updated" }
        let delta = max(0, now.timeIntervalSince(state.snapshot.fetchedAt))
        if delta < 5 { return "Just updated" }
        if delta < 60 { return "Updated \(Int(delta))s ago" }
        if delta < 3600 { return "Updated \(Int(delta / 60))m ago" }
        return "Updated \(Int(delta / 3600))h ago"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if displayedServices.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, OMSpacing.xs)
        } else if let service = selectedService {
            // This tab's own burn rate, not the dashboard's selection. The two
            // are separate persisted choices, so keying off the dashboard meant
            // the verdict either went missing or, worse, described a provider
            // that isn't on screen.
            ProviderDetail(service: service, burn: dashboard.burn(for: service.id))
        } else {
            allTab
        }
    }

    /// Every provider at a glance; tapping a tile is the same as picking its tab.
    private var allTab: some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: OMSpacing.s),
                    GridItem(.flexible(), spacing: OMSpacing.s),
                ],
                spacing: OMSpacing.s
            ) {
                ForEach(displayedServices) { service in
                    OMProviderTile(service: service) {
                        withAnimation(.smooth(duration: 0.2)) { selectedProviderTab = service.id }
                    }
                }
            }
            if OMCostTile.total(displayedServices) > 0 {
                OMCostTile(services: displayedServices)
            }
        }
    }

    /// Last-good data stays on screen; this row says why it isn't moving.
    private var staleNotice: some View {
        noticeRow(
            icon: "wifi.exclamationmark", tint: .orange,
            text: "Can't refresh — showing data from \(state.snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
        )
        .help(state.snapshot.lastError ?? "The last refresh attempt failed.")
    }

    private func noticeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: OMSpacing.s) {
            Rectangle()
                .fill(OMSurface.hairline)
                .frame(height: 0.5)
            HStack(spacing: 8) {
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "dashboard")
                        } label: {
                            Label("Dashboard", systemImage: "chart.bar.doc.horizontal")
                                .labelStyle(.titleAndIcon)
                        }
                        .glassButtonStyle()
                        .keyboardShortcut("d", modifiers: .command)
                        .help("Open dashboard (⌘D)")

                        Button {
                            FloatingWindowController.shared.toggle()
                        } label: {
                            Image(systemName: FloatingWindowController.shared.isOpen
                                  ? "pip.exit" : "pip.enter")
                        }
                        .glassButtonStyle()
                        .help(FloatingWindowController.shared.isOpen
                              ? "Close floating window" : "Show floating mini window")

                        Button {
                            NSApp.activate(ignoringOtherApps: true)
                            openSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .glassButtonStyle()
                        .keyboardShortcut(",", modifiers: .command)
                        .help("Settings (⌘,)")

                        Button {
                            state.refreshNow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .glassButtonStyle()
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh now (⌘R)")
                    }
                }

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(OMFont.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

// MARK: - Provider tab

private struct ProviderDetail: View {
    let service: ServiceSnapshot
    let burn: BurnRatePrediction?

    @State private var showUnusedWindows = false

    private var sessionBuckets: [UsageBucket] { service.buckets.filter { $0.kind == .session } }
    private var weeklyBuckets: [UsageBucket] { service.buckets.filter { $0.kind == .weekly || $0.kind == .modelSpecific } }
    /// Untouched model-specific windows are noise most of the day — fold them
    /// behind a disclosure row. "All models" stays visible even at zero.
    private var visibleWeekly: [UsageBucket] { weeklyBuckets.filter { $0.clampedPercent >= 0.05 || $0.id == "seven_day" } }
    private var unusedWeekly: [UsageBucket] { weeklyBuckets.filter { $0.clampedPercent < 0.05 && $0.id != "seven_day" } }
    private var hero: UsageBucket? { WindowRanking.heroBucket(for: service) }
    /// Weekly windows other than the one already shown as the hero.
    private var weeklyForRow: [UsageBucket] {
        let shown = visibleWeekly + (showUnusedWindows ? unusedWeekly : (unusedWeekly.count == 1 ? unusedWeekly : []))
        return shown.filter { $0.id != hero?.id }
    }
    private var nothingToShow: Bool {
        service.buckets.isEmpty && service.extraUsage == nil && (service.weekCost ?? 0) == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            if service.state != .ok {
                HStack {
                    if let msg = service.stateMessage, !msg.isEmpty {
                        Text(msg).font(OMFont.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer()
                    ServiceStateChip(service: service)
                }
            }
            // Last-good data is retained through a transient failure, so the
            // numbers below stay on screen whatever the state chip says.
            if let hero {
                OMHero(hero: hero, verdict: BurnVerdict.make(burn: burn, sessionBuckets: sessionBuckets))
            } else if service.state == .ok, let cost = service.weekCost, cost > 0 {
                // Pay-as-you-go without windows: the 7-day spend is the headline.
                OMKeyValueRow(label: "Last 7 days", value: OMCostTile.money(cost))
            }
            if !weeklyForRow.isEmpty {
                OMSectionHeader(title: "Weekly limits", trailing: weeklyReset)
                OMRingRow(buckets: weeklyForRow)
                unusedToggle
            } else if unusedWeekly.count > 1 {
                unusedToggle
            }
            if let extra = service.extraUsage, extra.isEnabled {
                OMKeyValueRow(
                    label: extraUsageTitle(plan: service.plan),
                    value: "\(OMCostTile.money(extra.usedCredits)) / \(extra.monthlyLimit.formatted(.currency(code: "USD").precision(.fractionLength(0))))",
                    barPercent: extra.utilization
                )
            }
            if hero != nil, let week = service.weekCost, week > 0 {
                OMKeyValueRow(label: "Last 7 days", value: OMCostTile.money(week))
            }
            if service.state == .ok, nothingToShow {
                Text("Server responded but returned no usage data.")
                    .font(OMFont.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// "resets in 2d 4h" for the all-models weekly; nil when unknown.
    private var weeklyReset: String? {
        guard let weekly = weeklyBuckets.first(where: { $0.id == "seven_day" }) ?? weeklyBuckets.first,
              let text = WindowRanking.remainingText(until: weekly.resetsAt) else { return nil }
        // Past the reset time the helper already says "resets now".
        guard text.hasSuffix(" left") else { return text }
        return "resets in \(text.replacingOccurrences(of: " left", with: ""))"
    }

    // A toggle row costs as much space as a ring row, so only fold when there
    // are at least two untouched windows (a single one is shown inline).
    @ViewBuilder
    private var unusedToggle: some View {
        if unusedWeekly.count > 1 {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showUnusedWindows.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showUnusedWindows ? 90 : 0))
                    Text(showUnusedWindows ? "Hide unused windows" : "\(unusedWeekly.count) unused windows")
                        .font(OMFont.caption)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - State chip with recovery help

/// The capsule reads as a button, so it must act like one: clicking walks the
/// user through fixing the state instead of doing nothing.
private struct ServiceStateChip: View {
    let service: ServiceSnapshot
    @State private var showsStateHelp = false

    var body: some View {
        let (text, color): (String, Color) = {
            switch service.state {
            case .notSignedIn: return ("Sign in", .orange)
            case .notRunning: return ("Not running", .secondary)
            case .error: return ("Error", .red)
            case .ok: return ("OK", .green)
            }
        }()
        Group {
            if let help = stateHelp {
                Button { showsStateHelp.toggle() } label: { OMChip(text: text, tint: color) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsStateHelp, arrowEdge: .bottom) { stateHelpContent(help) }
            } else {
                OMChip(text: text, tint: color)
            }
        }
    }

    private struct StateHelp {
        let message: String
        var command: String?
        var appPath: String?
        var linkTitle: String?
        var linkURL: String?
    }

    /// Per-service recovery instructions behind the state badge.
    private var stateHelp: StateHelp? {
        switch (service.id, service.state) {
        case ("claude", .notSignedIn):
            return StateHelp(
                message: "Sign into Claude Code in a terminal, then the widget picks it up on the next refresh.",
                command: "claude login"
            )
        case ("codex", .notSignedIn):
            return StateHelp(
                message: "Codex reports limits only for ChatGPT sign-in (API-key auth doesn't expose them).",
                command: "codex logout && codex login"
            )
        case ("gemini", .notSignedIn):
            return StateHelp(
                message: "Sign into the Gemini CLI with your Google account, then refresh.",
                command: "gemini"
            )
        case ("antigravity", _) where service.state != .ok:
            let installed = FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
            return StateHelp(
                message: "Antigravity shares quotas only while the app, `agy` CLI, or IDE is running.",
                command: installed ? nil : "agy",
                appPath: installed ? "/Applications/Antigravity.app" : nil
            )
        case ("grok", .notSignedIn):
            return StateHelp(
                message: "Sign into the Grok CLI, then refresh. Credits reset with your xAI billing period.",
                command: "grok login",
                linkTitle: "Open grok.com usage",
                linkURL: "https://grok.com/?_s=usage"
            )
        default:
            return nil
        }
    }

    private func stateHelpContent(_ help: StateHelp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(help.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let command = help.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if let appPath = help.appPath {
                Button("Open Antigravity") {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: appPath),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    showsStateHelp = false
                }
                .controlSize(.small)
            }
            if let title = help.linkTitle, let url = help.linkURL.flatMap(URL.init(string:)) {
                Link(title, destination: url)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

#Preview("Popover — All") {
    PopoverView(state: AppState.shared)
}

#Preview("Provider detail") {
    ProviderDetail(
        service: ServiceSnapshot(
            id: "claude",
            displayName: "Claude",
            icon: "sparkles",
            plan: "Max 20x",
            accountLabel: nil,
            buckets: [
                UsageBucket(id: "five_hour", label: "Current session", utilization: 34, resetsAt: Date().addingTimeInterval(2 * 3600), kind: .session),
                UsageBucket(id: "seven_day", label: "All models", utilization: 76, resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .weekly),
                UsageBucket(id: "seven_day_opus", label: "Opus only", utilization: 12, resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .modelSpecific),
                UsageBucket(id: "seven_day_fable", label: "Fable only", utilization: 93, resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .modelSpecific),
                UsageBucket(id: "seven_day_sonnet", label: "Sonnet only", utilization: 0, resetsAt: .distantFuture, kind: .modelSpecific),
                UsageBucket(id: "seven_day_cowork", label: "Cowork", utilization: 0, resetsAt: .distantFuture, kind: .modelSpecific),
            ],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25),
            weekCost: 41.37,
            state: .ok,
            stateMessage: nil,
            fetchedAt: Date()
        ),
        burn: BurnRatePrediction(secondsToLimit: 65 * 60, percentPerMinute: 1.0, bucketId: "five_hour", isStale: false)
    )
    .padding(OMSpacing.l)
    .frame(width: 360)
}
