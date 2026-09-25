import SwiftUI
import AppKit

/// Moves the window's close, minimize and zoom buttons to
/// `DashboardShellLayout.windowButtonsOrigin`, inside the floating sidebar, and grows
/// the title-bar strip down to them (`windowButtonsStripHeight`) so all of each button
/// takes clicks. AppKit puts both back to its own layout when the window resizes, so
/// they are placed again after every resize, on becoming key, when the window shows
/// again after a close, and when it leaves full screen; in full screen AppKit's layout
/// stays. Placed as a background, it takes no space and affects only its own window.
struct WindowButtonsPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView {
        PlacementView()
    }

    func updateNSView(_ nsView: PlacementView, context: Context) {}

    static func dismantleNSView(_ nsView: PlacementView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class PlacementView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    // Delivered on the main queue by contract; say so to the compiler.
                    MainActor.assumeIsolated { self?.placeButtons() }
                }
            }
            placeButtons()
            // SwiftUI finishes styling a new window after its content moves in; place
            // again once that pass is done.
            Task { @MainActor [weak self] in self?.placeButtons() }
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        private func placeButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let contentView = window.contentView,
                  let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let strip = close.superview,
                  minimize.superview === strip, zoom.superview === strip
            else { return }
            let buttons = [close, minimize, zoom]
            // The system's spacing, read before anything moves.
            let offsets = buttons.map { $0.frame.minX - close.frame.minX }
            // Window coordinates throughout, so neither view's flipping matters.
            let content = contentView.convert(contentView.bounds, to: nil)
            let origin = DashboardShellLayout.windowButtonsOrigin(
                closeButtonSize: close.frame.size, contentHeight: content.height
            )
            if let container = strip.superview, let host = container.superview {
                let needed = DashboardShellLayout.windowButtonsStripHeight(closeButtonSize: close.frame.size)
                let current = container.convert(container.bounds, to: nil)
                if current.height < needed {
                    let grown = NSRect(x: current.minX, y: current.maxY - needed, width: current.width, height: needed)
                    container.frame = host.convert(grown, from: nil)
                }
            }
            for (button, offset) in zip(buttons, offsets) {
                let target = NSRect(
                    x: content.minX + origin.x + offset,
                    y: content.minY + origin.y,
                    width: button.frame.width,
                    height: button.frame.height
                )
                button.setFrameOrigin(strip.convert(target, from: nil).origin)
            }
        }
    }
}
