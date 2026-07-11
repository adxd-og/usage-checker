import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    let statusItem: NSStatusItem
    private let popover: NSPopover
    nonisolated(unsafe) private var snapshotObserver: (any NSObjectProtocol)?
    private var tooltipTimer: Timer?

    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.animates = true
        self.popover.contentSize = NSSize(width: 340, height: 460)
        self.popover.contentViewController = NSHostingController(
            rootView: PopoverView(state: AppState.shared)
        )

        configureButton()
        observeSnapshotForTooltip()
        startTooltipTickTimer()
    }

    deinit {
        if let observer = snapshotObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func startTooltipTickTimer() {
        tooltipTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTooltip()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tooltipTimer = timer
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
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

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            AppState.shared.refreshNow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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

    private func updateTooltip() {
        let snap = AppState.shared.snapshot
        // Every provider with data gets a block — the tooltip used to be
        // hardcoded to Claude and stayed silent about the rest.
        let services = snap.services.filter { !$0.buckets.isEmpty || $0.weekCost != nil }
        guard !services.isEmpty else {
            statusItem.button?.toolTip = "Omelette — loading…"
            return
        }
        var lines: [String] = []
        for service in services {
            if !lines.isEmpty { lines.append("") }
            lines.append(service.plan ?? service.displayName)
            for b in service.buckets where b.clampedPercent > 0 || b.kind == .session || b.id == "seven_day" {
                lines.append("  \(b.label): \(Int(b.clampedPercent.rounded()))%")
            }
            if let cost = service.weekCost {
                lines.append(String(format: "  Last 7 days: $%.2f", cost))
            }
        }
        let updated = snap.fetchedAt
        if updated.timeIntervalSince1970 > 1 {
            lines.append("")
            lines.append("Updated \(formatAgo(updated))")
        }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    private func formatAgo(_ date: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(date))
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
}

private struct MenuBarHostView: View {
    @ObservedObject var state: AppState

    var body: some View {
        MenuBarLabel(snapshot: state.snapshot)
    }
}
