import AppKit

/// Applies `ActivationPolicyRules` as windows come and go. Every notification only schedules a
/// look at the actual windows on the next turn, so a burst of them settles to one decision, and
/// `willClose`, which fires while the window is still visible, is read after the close took
/// effect. Occlusion is the net for a window that showed or went without turning key.
@MainActor
final class ActivationPolicyController {
    private var refreshIsScheduled = false

    init() {
        let center = NotificationCenter.default
        for name: Notification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            center.addObserver(self, selector: #selector(windowsChanged(_:)), name: name, object: nil)
        }
        // A window restored at launch may have shown before these observers.
        scheduleRefresh()
    }

    @objc private func windowsChanged(_ note: Notification) {
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshIsScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let current = NSApp.activationPolicy()
        let policy = ActivationPolicyRules.policy(
            windows: NSApp.windows.map(ActivationPolicyRules.WindowFacts.init),
            appIsHidden: NSApp.isHidden,
            current: current
        )
        guard policy != current else { return }
        NSApp.setActivationPolicy(policy)
        if ActivationPolicyRules.activatesAfterChange(to: policy, appIsActive: NSApp.isActive) {
            NSApp.activate()
        }
    }
}

private extension ActivationPolicyRules.WindowFacts {
    @MainActor
    init(_ window: NSWindow) {
        self.init(
            isPanel: window is NSPanel,
            isTitled: window.styleMask.contains(.titled),
            isSheet: window.isSheet,
            hasParent: window.parent != nil || window.sheetParent != nil,
            canBecomeMain: window.canBecomeMain,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized
        )
    }
}
