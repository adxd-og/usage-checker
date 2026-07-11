import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var dashboard = DashboardState.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - Hero header

    /// The most-constrained window across all services — the one that answers
    /// "can I keep working right now?". Ties resolve to the first in API order
    /// (the 5-hour session), so an all-zero account leads with the session.
    /// Promotional pools don't compete (a free bonus running low isn't "almost
    /// at the limit"); an Enterprise spend limit does. Promo windows only lead
    /// when they're all the account has.
    private var heroBucket: UsageBucket? {
        var candidates = state.snapshot.services.flatMap { service in
            service.buckets.filter { !$0.isPromotional }
        }
        for service in state.snapshot.services {
            if let extra = service.extraUsage, extra.isEnabled {
                candidates.append(UsageBucket(
                    id: "\(service.id)_extra_usage",
                    label: extraUsageTitle(plan: service.plan),
                    utilization: extra.utilization,
                    resetsAt: .distantFuture,
                    kind: .other
                ))
            }
        }
        if candidates.isEmpty {
            candidates = state.snapshot.services.flatMap(\.buckets)
        }
        return candidates.enumerated().max { a, b in
            if a.element.clampedPercent != b.element.clampedPercent {
                return a.element.clampedPercent < b.element.clampedPercent
            }
            return a.offset > b.offset
        }?.element
    }

    /// The hero ring answers "how close am I to MY limit" — unambiguous only
    /// while a single provider is on screen. With several providers the number
    /// is anonymous (whose 33%?), so the header goes neutral and the
    /// per-provider sections below carry the percentages.
    private var showsHero: Bool {
        state.snapshot.services.filter { !$0.buckets.isEmpty || $0.weekCost != nil }.count == 1
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(spacing: 12) {
                if showsHero, let hero = heroBucket {
                    UsageRing(percent: hero.clampedPercent, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusPhrase(hero.clampedPercent))
                            .font(.headline)
                        Text(heroDetail(hero))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(hero.resetsAt < .distantFuture
                                  ? "Resets \(hero.resetsAt.formatted(date: .abbreviated, time: .shortened))"
                                  : "")
                        Text(metaLine(now: ctx.date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    // The real app icon, not a drawn stand-in — matches the
                    // welcome tour and tracks icon updates for free.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Omelette")
                            .font(.headline)
                        Text(updatedText(now: ctx.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func statusPhrase(_ percent: Double) -> String {
        if percent >= 90 { return "Almost at the limit" }
        if percent >= 70 { return "Running hot" }
        if percent >= 50 { return "On track" }
        return "Plenty of headroom"
    }

    private func heroDetail(_ hero: UsageBucket) -> String {
        if hero.resetsAt < .distantFuture {
            return "\(hero.label) · resets \(formatReset(hero.resetsAt))"
        }
        return hero.label
    }

    private func metaLine(now: Date) -> String {
        let updated = updatedText(now: now)
        if let plan = state.snapshot.services.compactMap(\.plan).first {
            return "\(plan) · \(updated)"
        }
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
        Divider().opacity(0.5)
        if state.snapshot.isStale && state.snapshot.hasAnyData {
            noticeRow(
                icon: "wifi.exclamationmark", tint: .orange,
                text: "Can't refresh — showing data from \(state.snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
            )
            .help(state.snapshot.lastError ?? "The last refresh attempt failed.")
        }
        if state.snapshot.services.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(state.snapshot.services) { service in
                    ServiceSection(
                        service: service,
                        burn: service.id == "claude" ? dashboard.burnFiveHour : nil,
                        showsHeader: service.state != .ok || state.snapshot.services.count > 1
                    )
                }
            }
        }
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
        VStack(spacing: 10) {
            Divider().opacity(0.5)
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
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

// MARK: - Per-service section

private struct ServiceSection: View {
    let service: ServiceSnapshot
    let burn: BurnRatePrediction?
    let showsHeader: Bool

    @State private var showUnusedWindows = false
    @State private var showsStateHelp = false

    private var sessionBuckets: [UsageBucket] {
        service.buckets.filter { $0.kind == .session }
    }

    private var weeklyBuckets: [UsageBucket] {
        service.buckets.filter { $0.kind == .weekly || $0.kind == .modelSpecific }
    }

    /// Untouched model-specific windows are noise most of the day — fold them
    /// behind a disclosure row. "All models" stays visible even at zero.
    private var visibleWeekly: [UsageBucket] {
        weeklyBuckets.filter { $0.clampedPercent >= 0.05 || $0.id == "seven_day" }
    }

    private var unusedWeekly: [UsageBucket] {
        weeklyBuckets.filter { $0.clampedPercent < 0.05 && $0.id != "seven_day" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                sectionHeader
            }

            switch service.state {
            case .ok:
                if !sessionBuckets.isEmpty {
                    sessionBlock
                }
                if !weeklyBuckets.isEmpty {
                    weeklyBlock
                }
                if let extra = service.extraUsage, extra.isEnabled {
                    extraBlock(extra)
                }
                if let week = service.weekCost, week > 0 {
                    weekCostBlock(week)
                }
                if service.buckets.isEmpty && service.extraUsage == nil && (service.weekCost ?? 0) == 0 {
                    Text("Server responded but returned no usage data.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            case .notSignedIn, .notRunning, .error:
                if let msg = service.stateMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                // Last-good data retained through a transient failure: keep showing
                // the numbers — the state badge already says what's wrong.
                if !service.buckets.isEmpty {
                    if !sessionBuckets.isEmpty { sessionBlock }
                    if !weeklyBuckets.isEmpty { weeklyBlock }
                    if let extra = service.extraUsage, extra.isEnabled {
                        extraBlock(extra)
                    }
                    if let week = service.weekCost, week > 0 {
                        weekCostBlock(week)
                    }
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: service.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName)
                    .font(.subheadline.weight(.semibold))
                if let plan = service.plan {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if service.state != .ok {
                stateBadge
            }
        }
    }

    private var stateBadge: some View {
        let (text, color): (String, Color) = {
            switch service.state {
            case .notSignedIn: return ("Sign in", .orange)
            case .notRunning: return ("Not running", .secondary)
            case .error: return ("Error", .red)
            case .ok: return ("OK", .green)
            }
        }()
        let label = Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlass(in: Capsule(), tint: color)

        // The capsule reads as a button, so it must act like one: clicking walks
        // the user through fixing the state instead of doing nothing.
        return Group {
            if let help = stateHelp {
                Button {
                    showsStateHelp.toggle()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsStateHelp, arrowEdge: .bottom) {
                    stateHelpContent(help)
                }
            } else {
                label
            }
        }
    }

    private struct StateHelp {
        let message: String
        var command: String?
        var appPath: String?
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
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    // MARK: Session

    private var sessionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Current session")
            ForEach(sessionBuckets) { bucket in
                bucketRow(bucket)
            }
            if let verdict = burnVerdict {
                HStack(spacing: 6) {
                    Image(systemName: verdict.willHit ? "flame.fill" : "checkmark.circle")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(verdict.willHit ? Color.orange : Color.secondary)
                    Text(verdict.text)
                        .font(.caption)
                        .foregroundStyle(verdict.willHit ? Color.primary : Color.secondary)
                    Spacer()
                }
            }
        }
    }

    /// Answers the question the burn rate is actually for: will I hit the limit
    /// before the window resets, or can I keep going at this pace?
    private var burnVerdict: (willHit: Bool, text: String)? {
        guard let burn, !burn.isStale,
              let secs = burn.secondsToLimit,
              let bucket = sessionBuckets.first(where: { $0.id == burn.bucketId })
        else { return nil }
        if bucket.resetsAt < .distantFuture, secs >= bucket.resetsAt.timeIntervalSinceNow {
            return (false, "At this pace you won't hit the limit before reset")
        }
        return (true, "At this pace, limit in ~\(formatBurn(secs))")
    }

    private func formatBurn(_ secs: TimeInterval) -> String {
        let h = Int(secs / 3600)
        let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
        if h > 24 { return "\(h / 24)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: Weekly

    private var weeklyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            blockTitle("Weekly limits")
            ForEach(visibleWeekly) { bucket in
                bucketRow(bucket)
            }
            // A toggle row costs as much space as a single bucket row, so only
            // fold when there are at least two untouched windows.
            if unusedWeekly.count == 1, let only = unusedWeekly.first {
                bucketRow(only)
            } else if unusedWeekly.count > 1 {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { showUnusedWindows.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showUnusedWindows ? 90 : 0))
                        Text(showUnusedWindows
                             ? "Hide unused windows"
                             : "\(unusedWeekly.count) unused windows")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showUnusedWindows {
                    ForEach(unusedWeekly) { bucket in
                        bucketRow(bucket)
                    }
                }
            }
        }
    }

    private func blockTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func bucketRow(_ bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bucket.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if bucket.resetsAt < Date.distantFuture {
                    Text("resets \(formatReset(bucket.resetsAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Resets \(bucket.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                } else if bucket.clampedPercent == 0 {
                    Text(emptyHint(for: bucket))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let pace = bucket.elapsedFraction() {
                BarSegment(percent: bucket.clampedPercent, height: 7, showsLabel: true, pace: pace)
                    .help("\(Int((pace * 100).rounded()))% of this window has elapsed — the tick marks even pace")
            } else {
                BarSegment(percent: bucket.clampedPercent, height: 7, showsLabel: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bucket.label), \(Int(bucket.clampedPercent.rounded())) percent used")
    }

    private func emptyHint(for bucket: UsageBucket) -> String {
        if bucket.id == "seven_day_oauth_apps" { return "No OAuth apps yet" }
        guard bucket.kind == .modelSpecific else { return "" }
        // "Opus only" → "You haven't used Opus yet"; works for any bucket label.
        var name = bucket.label
        if name.hasSuffix(" only") { name.removeLast(" only".count) }
        return "You haven't used \(name) yet"
    }

    private var extraUsageLabel: String { extraUsageTitle(plan: service.plan) }

    private func extraBlock(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(extraUsageLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Self.money(extra.usedCredits)) / \(Self.money(extra.monthlyLimit, decimals: 0))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            BarSegment(percent: extra.utilization, height: 6, showsLabel: false)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(extraUsageLabel), \(Self.money(extra.usedCredits)) of \(Self.money(extra.monthlyLimit, decimals: 0)) used")
    }

    private func weekCostBlock(_ amount: Double) -> some View {
        HStack {
            Text("Last 7 days")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(Self.money(amount))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.top, 2)
    }

    /// "$1,564.20" — grouped thousands so Enterprise-scale figures stay readable.
    private static func money(_ value: Double, decimals: Int = 2) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(decimals)))
    }
}

// MARK: - Shared formatting

private func formatReset(_ date: Date) -> String {
    let delta = date.timeIntervalSinceNow
    if delta <= 0 { return "now" }
    let f = DateComponentsFormatter()
    f.allowedUnits = [.day, .hour, .minute]
    f.maximumUnitCount = 2
    f.unitsStyle = .abbreviated
    return f.string(from: delta).map { "in \($0)" } ?? "—"
}

#Preview("Service section") {
    ServiceSection(
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
        burn: BurnRatePrediction(secondsToLimit: 65 * 60, percentPerMinute: 1.0, bucketId: "five_hour", isStale: false),
        showsHeader: true
    )
    .padding(16)
    .frame(width: 360)
}
