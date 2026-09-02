import SwiftUI
import AppKit

@MainActor
final class FloatingWindowController {
    static let shared = FloatingWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<FloatingMiniView>?

    private init() {}

    var isOpen: Bool { window != nil && window?.isVisible == true }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 260, height: 130)
        let win = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true

        let host = NSHostingView(rootView: FloatingMiniView(state: AppState.shared) { [weak self] in
            self?.close()
        })
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        win.contentView = host

        // Position bottom-right of the main screen
        if let screen = NSScreen.main {
            let rect = screen.visibleFrame
            let origin = NSPoint(
                x: rect.maxX - size.width - 20,
                y: rect.minY + 20
            )
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        window = win
        hostingView = host
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
        hostingView = nil
    }
}

struct FloatingMiniView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var dashboard = DashboardState.shared
    /// Observed here rather than in a slot view: the whole window is four rows,
    /// so re-evaluating it on a hook event costs less than the extra view does.
    @ObservedObject private var agents = AgentSessionStore.shared
    let onClose: () -> Void

    init(state: AppState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
    }

    /// Follows the dashboard's provider selection, so the two windows never
    /// disagree about whose numbers are on screen.
    private var service: ServiceSnapshot? {
        state.snapshot.services.first(where: { $0.id == dashboard.selectedService })
            ?? state.snapshot.services.first
    }

    var body: some View {
        FloatingMiniContent(
            service: service,
            agents: FloatingMiniLayout.agents(agents.sessions),
            onClose: onClose
        )
    }
}

/// Everything the window draws, with no singletons in it — which is what lets
/// both colour schemes and every empty state be previewed without a running app.
struct FloatingMiniContent: View {
    let service: ServiceSnapshot?
    var agents: OMAgentsPill.Appearance? = nil
    let onClose: () -> Void

    /// The panel is a fixed 260 × 130 (`FloatingWindowController.open`). A hero
    /// ring plus two bar rows fits at 6 pt; at `OMSpacing.s` the second row
    /// clips. This window is the one place where the token is too generous.
    private static let stackSpacing: CGFloat = 6
    /// Wide enough for "All models" shortened to "All" and for "Opus only" → "Opus".
    private static let rowLabelWidth: CGFloat = 62

    private var content: FloatingMiniLayout.Content {
        FloatingMiniLayout.content(for: service)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.stackSpacing) {
            header
            if let hero = content.hero {
                heroRow(hero)
                ForEach(content.rows) { bucket in
                    windowRow(bucket)
                }
            } else if let emptyText = content.emptyText {
                Text(emptyText)
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OMSpacing.m)
        .padding(.vertical, OMSpacing.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                .strokeBorder(OMSurface.hairline, lineWidth: 0.5)
        )
        .padding(2)
    }

    private var header: some View {
        HStack(spacing: OMSpacing.xs) {
            if let service {
                ProviderIconView(serviceID: service.id, sfFallback: service.icon, size: 12)
                    .foregroundStyle(.tint)
                    .frame(width: 14)
                Text(service.plan ?? service.displayName)
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Omelette")
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: OMSpacing.xs)
            if let agents {
                HStack(spacing: OMSpacing.xs) {
                    Circle()
                        .fill(agents.dot)
                        .frame(width: 6, height: 6)
                    Text(agents.text)
                        .font(OMFont.menuNumeral)
                        .monospacedDigit()
                        .foregroundStyle(agents.textColor)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(agents.accessibilityLabel)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
    }

    private func heroRow(_ hero: UsageBucket) -> some View {
        HStack(spacing: OMSpacing.m) {
            OMRing(percent: hero.clampedPercent, size: .medium, pace: hero.elapsedFraction())
            VStack(alignment: .leading, spacing: 2) {
                Text(hero.label)
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                if let remaining = WindowRanking.remainingText(until: hero.resetsAt) {
                    Text(remaining)
                        .font(OMFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hero.label), \(Int(hero.clampedPercent.rounded())) percent used")
    }

    private func windowRow(_ bucket: UsageBucket) -> some View {
        HStack(spacing: OMSpacing.s) {
            Text(WindowRanking.shortWindowLabel(bucket.label))
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.rowLabelWidth, alignment: .leading)
            BarSegment(
                percent: bucket.clampedPercent,
                height: 4,
                showsLabel: false,
                pace: bucket.elapsedFraction()
            )
            Text("\(Int(bucket.clampedPercent.rounded()))%")
                .font(OMFont.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bucket.label), \(Int(bucket.clampedPercent.rounded())) percent used")
    }
}

#if DEBUG
private func floatingPreviewService(buckets: [UsageBucket]) -> ServiceSnapshot {
    ServiceSnapshot(
        id: "claude",
        displayName: "Claude",
        icon: "sparkles",
        plan: "Max 20x",
        accountLabel: nil,
        buckets: buckets,
        extraUsage: nil,
        weekCost: 12.4,
        state: .ok,
        stateMessage: nil,
        fetchedAt: Date()
    )
}

private var floatingPreviewBuckets: [UsageBucket] {
    [
        UsageBucket(id: "five_hour", label: "Current session", utilization: 37,
                    resetsAt: Date().addingTimeInterval(8100), kind: .session),
        UsageBucket(id: "seven_day", label: "All models", utilization: 76,
                    resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .weekly),
        UsageBucket(id: "seven_day_opus", label: "Opus only", utilization: 12,
                    resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .modelSpecific),
    ]
}

#Preview("Floating — two agents, light") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: OMAgentsPill.Appearance.make(needsYou: 0, working: 2, total: 3),
        onClose: {}
    )
    .frame(width: 260, height: 130)
}

#Preview("Floating — two agents, dark") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: OMAgentsPill.Appearance.make(needsYou: 0, working: 2, total: 3),
        onClose: {}
    )
    .frame(width: 260, height: 130)
    .preferredColorScheme(.dark)
}

#Preview("Floating — one needs you") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: OMAgentsPill.Appearance.make(needsYou: 1, working: 2, total: 4),
        onClose: {}
    )
    .frame(width: 260, height: 130)
}

#Preview("Floating — no agents") {
    FloatingMiniContent(
        service: floatingPreviewService(buckets: floatingPreviewBuckets),
        agents: nil,
        onClose: {}
    )
    .frame(width: 260, height: 130)
}

#Preview("Floating — nothing tracked yet") {
    FloatingMiniContent(service: floatingPreviewService(buckets: []), agents: nil, onClose: {})
        .frame(width: 260, height: 130)
}
#endif
