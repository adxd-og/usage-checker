import Foundation

/// When the dashboard's detail column has to be built again from scratch, and
/// when a snapshot may be applied to it at all.
///
/// A SwiftUI `Window` that the user closes is hidden, not destroyed: its view
/// hierarchy lives on, and so do its subscriptions. On macOS 27.0 a text created
/// inside that hidden window (the Tokens today rows and the model rows that the
/// first turn of a new day brings back, a burn verdict that appears) is drawn
/// upside down once the window is shown again, and stays so until its string
/// changes or the view is rebuilt on a visible window. Sleep, screen lock and a
/// closed window are just three ways of hiding the window; 2.6.2 and 2.6.3
/// rebuilt on resume and missed the closed-window case.
///
/// Two decisions. Snapshots arriving while the window is hidden are not applied
/// by this window (other publishers still reach it; the rebuild is the cure, the
/// gate only saves work). And the column is rebuilt when the window comes back on
/// screen — but only if a poll happened while it was hidden: a rebuild resets
/// scroll positions and expanded rows, and a window that was merely covered for
/// a moment had nothing inserted into it.
struct DetailRebuildRule {
    private var visible = false
    private var pollsWhileHidden = 0

    /// The window's occlusion state, as sampled on attach and on every change.
    /// True exactly when the window has just come back on screen after a poll
    /// arrived while it was hidden: rebuild the column now.
    mutating func windowVisibilityChanged(_ nowVisible: Bool) -> Bool {
        let cameBack = nowVisible && !visible
        visible = nowVisible
        if !nowVisible { return false }
        defer { pollsWhileHidden = 0 }
        return cameBack && pollsWhileHidden > 0
    }

    /// A snapshot arrived. True when this window should apply it; while hidden it
    /// is only counted, so the next return to the screen knows to rebuild.
    mutating func snapshotArrived() -> Bool {
        if !visible { pollsWhileHidden += 1 }
        return visible
    }
}
