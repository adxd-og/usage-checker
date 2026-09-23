import SwiftUI
import AppKit

/// Reports whether the window this view sits in is on screen, through
/// `NSWindow.didChangeOcclusionStateNotification`: false once the window is
/// closed (hidden), fully covered, on another Space, minimized or behind the lock
/// screen; true again when it shows. The current state is reported on attach as
/// well, so a reader joining an already visible window starts right. Placed as a
/// background, it takes no space.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                onChange?(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                // Delivered on the main queue by contract; say so to the compiler.
                // The window is read through the weak capture, not the notification:
                // `Notification` is not Sendable and cannot cross into the actor.
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.onChange?(window.occlusionState.contains(.visible))
                }
            }
            onChange?(window.occlusionState.contains(.visible))
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
