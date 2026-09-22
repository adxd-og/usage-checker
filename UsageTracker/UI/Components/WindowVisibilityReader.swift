import SwiftUI
import AppKit

/// Reports whether the window this view sits in is on screen, through
/// `NSWindow.didChangeOcclusionStateNotification`: false once the window is
/// closed (hidden), covered, on another Space, behind the lock screen or a dark
/// display; true again when it shows. Placed as a background, it takes no space.
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

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving a window (including the view's own teardown) drops the
            // observer here; a nonisolated deinit cannot touch it.
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let self, let window = note.object as? NSWindow else { return }
                self.onChange?(window.occlusionState.contains(.visible))
            }
        }
    }
}
