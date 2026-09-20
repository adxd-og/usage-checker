import Foundation

/// When the dashboard's detail column has to be built again from scratch.
///
/// macOS 27.0 leaves the column's scroll container in a bad state after a screen
/// lock or sleep: every text *inserted* into it afterwards is drawn upside down
/// (the Tokens today rows and the model rows that the first turn of a new day
/// brings back, the burn line), while texts that were already there stay right.
/// A resize does not help; a fresh column does, which is what switching tabs
/// proved. So the column is rebuilt once per resume — not at the resume itself,
/// when the lock screen may still be up (2.6.2 tried `screensDidWake` and the
/// rebuilt column came out just as bad), but on the first snapshot after it, so
/// the refresh that would insert the rows lands in the new column.
struct DetailRebuildRule {
    private var armed = false

    /// The system came back from sleep or the screen was unlocked.
    mutating func resumed() {
        armed = true
    }

    /// A snapshot arrived. True exactly once after a resume: rebuild the column.
    mutating func snapshotArrived() -> Bool {
        defer { armed = false }
        return armed
    }
}
