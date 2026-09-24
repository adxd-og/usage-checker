import Foundation

/// Whether a calculation the dashboard ran off the main actor may still publish.
///
/// The Activity grid, the Insights cards, History's quota chart and an open chat's
/// breakdown each build in a `Task.detached` started from a `.task(id:)`. SwiftUI
/// cancels that task when its id changes, but awaiting a detached task's `value` does
/// not stop for the cancellation: the await returns when the work is done and the
/// assignment after it used to run regardless. A slow Claude pass finishing after a
/// fast Grok one painted Claude's grid under the Grok tab for minutes.
///
/// Each caller captures its key before the await and asks here before assigning — the
/// same two halves `DashboardState.canPublish` checks for the dashboard's own passes.
enum DerivedCacheGate {
    /// `started` is the key the pass was launched for, `current` the key the view holds
    /// now, `cancelled` is `Task.isCancelled` read after the await.
    static func canPublish<Key: Equatable>(started: Key, current: Key, cancelled: Bool) -> Bool {
        !cancelled && started == current
    }
}
