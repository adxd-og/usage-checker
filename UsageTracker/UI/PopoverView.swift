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

    // MARK: - Header

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage Checker")
                        .font(.headline)
                    Text(updatedText(now: ctx.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
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
        if case .active(let endsAt) = Announcements.weeklyBonus() {
            noticeRow(
                icon: "sparkles", tint: .green,
                text: "Weekly limits +50% until \(endsAt.formatted(date: .abbreviated, time: .omitted))"
            )
        }
        if case .active(let endsAt) = Announcements.fableIncluded() {
            noticeRow(
                icon: "wand.and.stars", tint: .purple,
                text: "Fable 5 included until \(endsAt.formatted(date: .abbreviated, time: .omitted)) — then uses extra credits"
            )
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
                    ServiceSection(service: service)
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
            if let hint = burnHint {
                Divider().opacity(0.5)
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
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
                        .help("Settings")

                        Button {
                            state.refreshNow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .glassButtonStyle()
                        .help("Refresh now")
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
            }
        }
    }

    private var burnHint: String? {
        guard let burn = dashboard.burnFiveHour,
              let secs = burn.secondsToLimit else { return nil }
        return "5h window: hit limit in ~\(formatBurn(secs))"
    }

    private func formatBurn(_ secs: TimeInterval) -> String {
        let h = Int(secs / 3600)
        let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
        if h > 24 {
            let d = h / 24
            return "\(d)d"
        }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

private struct ServiceSection: View {
    let service: ServiceSnapshot

    private var sessionBuckets: [UsageBucket] {
        service.buckets.filter { $0.kind == .session }
    }

    private var weeklyBuckets: [UsageBucket] {
        service.buckets.filter { $0.kind == .weekly || $0.kind == .modelSpecific }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader

            switch service.state {
            case .ok:
                if !sessionBuckets.isEmpty {
                    bucketsBlock(title: "Current session", buckets: sessionBuckets)
                }
                if !weeklyBuckets.isEmpty {
                    bucketsBlock(title: "Weekly limits", buckets: weeklyBuckets)
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
            case .notRunning: return ("Idle", .secondary)
            case .error: return ("Error", .red)
            case .ok: return ("OK", .green)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .liquidGlass(in: Capsule(), tint: color)
    }

    private func bucketsBlock(title: String, buckets: [UsageBucket]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ForEach(buckets) { bucket in
                bucketRow(bucket)
            }
        }
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
                } else if bucket.clampedPercent == 0 {
                    Text(emptyHint(for: bucket))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            BarSegment(
                percent: bucket.clampedPercent,
                height: 7,
                showsLabel: true,
                pace: paceFraction(for: bucket)
            )
        }
    }

    /// Fraction of the bucket's rate-limit window already elapsed (0...1), so the
    /// pace tick can show whether usage runs ahead of or behind "even pace".
    private func paceFraction(for bucket: UsageBucket) -> Double? {
        guard bucket.resetsAt < .distantFuture else { return nil }
        let duration: TimeInterval
        switch bucket.kind {
        case .session: duration = 5 * 3600
        case .weekly, .modelSpecific: duration = 7 * 24 * 3600
        case .other: return nil
        }
        let remaining = bucket.resetsAt.timeIntervalSinceNow
        guard remaining > 0, remaining <= duration else { return nil }
        return 1 - remaining / duration
    }

    private func emptyHint(for bucket: UsageBucket) -> String {
        if bucket.id == "seven_day_oauth_apps" { return "No OAuth apps yet" }
        guard bucket.kind == .modelSpecific else { return "" }
        // "Opus only" → "You haven't used Opus yet"; works for any bucket label.
        var name = bucket.label
        if name.hasSuffix(" only") { name.removeLast(" only".count) }
        return "You haven't used \(name) yet"
    }

    private func extraBlock(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Extra usage credits")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "$%.2f / $%.0f", extra.usedCredits, extra.monthlyLimit))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            BarSegment(percent: extra.utilization, height: 6, showsLabel: false)
        }
        .padding(.top, 2)
    }

    private func weekCostBlock(_ amount: Double) -> some View {
        HStack {
            Text("Last 7 days")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(String(format: "$%.2f", amount))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.top, 2)
    }

    private func formatReset(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 { return "now" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: delta).map { "in \($0)" } ?? "—"
    }
}

#Preview("Service section") {
    ServiceSection(service: ServiceSnapshot(
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
        ],
        extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25),
        weekCost: 41.37,
        state: .ok,
        stateMessage: nil,
        fetchedAt: Date()
    ))
    .padding(16)
    .frame(width: 360)
}
