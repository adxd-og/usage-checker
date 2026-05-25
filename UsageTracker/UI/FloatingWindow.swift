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
    let onClose: () -> Void

    private var claude: ServiceSnapshot? {
        state.snapshot.services.first(where: { $0.id == "claude" })
    }

    private var fiveHour: UsageBucket? {
        claude?.buckets.first(where: { $0.id == "five_hour" })
    }

    private var sevenDay: UsageBucket? {
        claude?.buckets.first(where: { $0.id == "seven_day" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        LinearGradient(colors: [.accentColor, .cyan.opacity(0.8)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 18, height: 18)
                    .overlay(Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white))
                Text(claude?.plan ?? "Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.borderless)
            }

            row(label: "5-hour", bucket: fiveHour)
            row(label: "7-day", bucket: sevenDay)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
        )
        .padding(2)
    }

    private func row(label: String, bucket: UsageBucket?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                if let b = bucket {
                    Text("\(Int(b.clampedPercent.rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barGradient(percent: bucket?.clampedPercent ?? 0))
                        .frame(width: geo.size.width * CGFloat((bucket?.clampedPercent ?? 0) / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private func barGradient(percent: Double) -> LinearGradient {
        let colors: [Color]
        if percent >= 90 { colors = [.red, .orange] }
        else if percent >= 70 { colors = [.orange, .yellow] }
        else if percent >= 40 { colors = [.cyan, .blue] }
        else { colors = [.green, .mint] }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
