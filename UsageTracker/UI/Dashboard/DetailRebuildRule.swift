import Foundation

/// When the dashboard's detail column has to be built again from scratch, and
/// when a snapshot may be applied to it at all.
///
/// A SwiftUI `Window` that the user closes is hidden, not destroyed: its view
/// hierarchy lives on, and so does its snapshot subscription. On macOS 27.0 a
/// text created inside that hidden window (the Tokens today rows and the model
/// rows that the first turn of a new day brings back, a burn verdict that
/// appears) is drawn upside down once the window is shown again, and stays so
/// until its string changes or the view is rebuilt on a visible window. Sleep,
/// screen lock and a closed window are just three ways of hiding the window;
/// 2.6.2 and 2.6.3 rebuilt on resume and missed the closed-window case.
///
/// So: nothing is applied while the window is hidden, and the column is rebuilt
/// the moment the window is back on screen, before the refresh that follows.
struct DetailRebuildRule {
    private var visible = true

    /// The window's occlusion state changed. True exactly when the window has
    /// just come back on screen: rebuild the column now.
    mutating func windowVisibilityChanged(_ nowVisible: Bool) -> Bool {
        defer { visible = nowVisible }
        return nowVisible && !visible
    }

    /// Snapshots arriving while the window is hidden are dropped; the refresh
    /// that runs when the window shows again catches the column up.
    var appliesSnapshots: Bool { visible }
}
