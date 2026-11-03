import AppKit
import SwiftUI
import Combine

/// The status item: its pills, its tooltip, and its click, which opens and closes the island
/// (notch-island spec 2026-10-29 § 3.1, Entry points). Shown per Show in menu bar (§ 3.7,
/// D4). The island is `IslandController`'s.
@MainActor
final class StatusBarController: NSObject {
    /// The item while it is shown; nil while Show in menu bar hides it. Removed and made
    /// again rather than set invisible: `isVisible = false` is saved under the item's
    /// autosave name in the defaults domain a 3.x copy shares, which would then start with no
    /// item and no notch to open it from (ruling R9).
    private(set) var statusItem: NSStatusItem?
    private let island: IslandController
    nonisolated(unsafe) private var snapshotObserver: (any NSObjectProtocol)?
    /// The tooltip's keep-awake line follows the model, not only the snapshot.
    private var keepAwakeObserver: AnyCancellable?
    /// Show in menu bar, as `SettingsStore` publishes it.
    private var visibilityObserver: AnyCancellable?

    init(island: IslandController) {
        self.island = island
        super.init()
        // The snapshot notification is the only tooltip trigger: the data changes
        // once per poll, so a wall-clock tick timer on top of it was pure waste
        // (and was never invalidated).
        observeSnapshotForTooltip()
        observeKeepAwakeForTooltip()
        // A click on the item is its own toggle's, never also an outside click.
        island.statusItemWindow = { [weak self] in self?.statusItem?.button?.window }
        // Whenever the island's pills change their set (a space whose menu bar goes or comes back, a
        // click on a pill its display had left behind), the item follows.
        island.updateStatusItemVisibility = { [weak self] in
            self?.updateVisibility(setting: SettingsStore.shared.showInMenuBar)
        }
        observeVisibility()
    }

    deinit {
        if let observer = snapshotObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Shown or hidden (§ 3.7, D4)

    private func observeVisibility() {
        // `@Published` sends before the property changes, so the sent value is the new one;
        // the first send is the current value, which places the item at launch.
        visibilityObserver = SettingsStore.shared.$showInMenuBar
            .sink { [weak self] setting in
                self?.updateVisibility(setting: setting)
            }
        // A display gaining or losing the island (a lid, an external display, a menu bar that hides) moves the answer.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // A lid closed during sleep moves it too, the same signals `IslandController` re-reads on.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            workspace.addObserver(self, selector: #selector(woke(_:)), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(woke(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )
    }

    @objc private func screensChanged(_ note: Notification) {
        updateVisibility(setting: SettingsStore.shared.showInMenuBar)
    }

    /// Read now and a second later, since the first read of the screens after these can be stale
    /// (`IslandController.woke`, P0 run 1). A stale "island display attached" would leave no item
    /// and no notch to open the island from.
    @objc private func woke(_ note: Notification) {
        updateVisibility(setting: SettingsStore.shared.showInMenuBar)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.updateVisibility(setting: SettingsStore.shared.showInMenuBar)
        }
    }

    private func updateVisibility(setting: Bool?) {
        let shown = StatusItemVisibilityRules.isShown(
            setting: setting,
            islandDisplayAttached: StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.current())
        )
        if shown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // AppKit names the first item "Item-0" and keeps its menu-bar position under
            // that name in the defaults 3.x shares; a recreated item would get a new name
            // and lose the place the user dragged it to.
            item.autosaveName = "Item-0"
            statusItem = item
            configureButton(item)
        } else if !shown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func configureButton(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        button.action = #selector(toggleIsland)
        button.target = self

        let host = NSHostingView(rootView: MenuBarHostView(state: AppState.shared))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        updateTooltip()
    }

    /// The item opens the island on its own display (a panel under it when that display has
    /// no island, spec 2026-11-03) and closes it when it is open (§ 3.1).
    @objc private func toggleIsland() {
        guard let frame = statusItem?.button?.window?.frame else { return }
        island.handle(.statusItem(buttonFrame: frame))
    }

    private func observeSnapshotForTooltip() {
        snapshotObserver = NotificationCenter.default.addObserver(
            forName: .snapshotUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTooltip()
            }
        }
    }

    /// `@Published` sends before the property changes, so the tooltip is built from the
    /// value delivered here, not from `KeepAwakeModel.shared.state` (still the old one).
    /// The model is `@MainActor` like this controller: a plain call, as in `UsageNotifier`.
    private func observeKeepAwakeForTooltip() {
        keepAwakeObserver = KeepAwakeModel.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.updateTooltip(keepAwake: state)
            }
    }

    private func updateTooltip(keepAwake: KeepAwakeState? = nil) {
        statusItem?.button?.toolTip = Self.tooltipText(
            snapshot: AppState.shared.snapshot,
            mode: SettingsStore.shared.percentMode,
            keepAwake: keepAwake ?? KeepAwakeModel.shared.state,
            pollsNothing: AppState.shared.pollsNothing
        )
    }

    /// Every line of the status item's tooltip, from the snapshot alone. Pure, so
    /// the wording — and which way each number counts — is unit-tested rather than
    /// eyeballed on a hover.
    ///
    /// Every provider with data gets a block; a retained one is headed by the line
    /// that says why its numbers aren't moving, a healthy one by its plan. While keep
    /// awake is on, its line comes first (keep-awake spec 2026-10-26, § UI). With every
    /// provider off (`pollsNothing`) the usage part is `NothingOnCopy.tooltip` instead of
    /// "loading…" for good (spec 2026-10-25 § Package 1).
    nonisolated static func tooltipText(
        snapshot: UsageSnapshot,
        mode: PercentDisplay.Mode = .used,
        keepAwake: KeepAwakeState = .idle,
        pollsNothing: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let usage = pollsNothing
            ? NothingOnCopy.tooltip
            : usageTooltip(snapshot: snapshot, mode: mode, now: now, calendar: calendar, locale: locale)
        guard let line = KeepAwakeCopy.tooltipLine(keepAwake, now: now, calendar: calendar, locale: locale) else {
            return usage
        }
        return "\(line)\n\n\(usage)"
    }

    /// The tooltip's usage part: one block per provider with data, then when it was updated.
    nonisolated private static func usageTooltip(
        snapshot: UsageSnapshot,
        mode: PercentDisplay.Mode,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let services = snapshot.services.filter { !$0.buckets.isEmpty || $0.weekCost != nil }
        guard !services.isEmpty else { return "Brioche — loading…" }
        var lines: [String] = []
        for service in services {
            if !lines.isEmpty { lines.append("") }
            lines.append(service.isRetained
                         ? MenuBarLabel.text(for: service, mode: mode, now: now,
                                             calendar: calendar, locale: locale)
                         : (service.plan ?? service.displayName))
            // Which windows appear is a question about usage, not about display: an
            // untouched window is hidden at 0% used, and it is still the untouched
            // window when the app is counting down from 100.
            for b in service.buckets where b.clampedPercent > 0 || b.kind == .session || b.id == "seven_day" {
                // A prepaid credit pool is money, not a window counting down: its line
                // says what the Claude tab's row says, "$231 / $250", in either mode.
                if let credit = b.credit {
                    let dollars = CreditCopy.value(
                        usedDollars: credit.usedDollars, limitDollars: credit.limitDollars, locale: locale
                    )
                    lines.append("  \(b.label): \(dollars)")
                    continue
                }
                lines.append("  \(b.label): \(PercentDisplay.percentPhrase(b.clampedPercent, mode: mode))")
            }
            if let cost = service.weekCost {
                lines.append(String(format: "  Last 7 days: $%.2f", cost))
            }
        }
        let updated = snapshot.fetchedAt
        if updated.timeIntervalSince1970 > 1 {
            lines.append("")
            lines.append("Updated \(ago(updated, now: now))")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func ago(_ date: Date, now: Date = Date()) -> String {
        let delta = max(0, now.timeIntervalSince(date))
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(Int(delta)) sec ago" }
        if delta < 3600 {
            let m = Int(delta / 60)
            return "\(m) min ago"
        }
        if delta < 24 * 3600 {
            let h = Int(delta / 3600)
            let m = Int(delta.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
        }
        let d = Int(delta / (24 * 3600))
        return "\(d)d ago"
    }
}

extension Notification.Name {
    static let snapshotUpdated = Notification.Name("com.usagetracker.snapshotUpdated")
    /// Posted when something outside the status item wants the island on screen: an agent
    /// notification the user acted on (`UsageNotifier`). Opens it on the display under the
    /// pointer and leaves an open island open (notch-island spec 2026-10-29 § 3.1).
    static let showPopover = Notification.Name("com.usagetracker.showPopover")
}

private struct MenuBarHostView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            KeepAwakeMarkerSlot()
            MenuBarLabel(snapshot: state.snapshot)
        }
    }
}

/// The keep-awake marker before the label (spec 2026-10-26, § UI, Menu bar). Its own view
/// observing the model, as `AgentsPillSlot` observes the agent store, so a model change
/// redraws this glyph and not the provider pills; outside `MenuBarLabel`, so stale usage
/// does not dim it. VoiceOver reads the tooltip's line.
private struct KeepAwakeMarkerSlot: View {
    @ObservedObject private var model = KeepAwakeModel.shared

    var body: some View {
        let now = Date()
        if let marker = KeepAwakeCopy.menuBarMarker(model.state, now: now) {
            Text(marker)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.leading, 2)
                .accessibilityLabel(KeepAwakeCopy.tooltipLine(model.state, now: now) ?? "")
        }
    }
}
