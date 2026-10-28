import Foundation

/// What Omelette says when no provider is on: every switch in Settings › Providers is off
/// and no Admin API key is set (spec 2026-10-25 § Design › Package 1, Nothing on). Before
/// Claude had a switch this could not happen, and an empty poll meant "still loading";
/// every surface takes its words from here so they agree.
///
/// Foundation only: the widget extension compiles this file by path (project.yml), as it
/// does `PercentDisplay.swift`.
enum NothingOnCopy {
    /// The fact, as a heading.
    static let title = "All providers are off"
    /// Where to change it. "Providers" is the Settings tab's own name, which the widget
    /// cannot see; a test holds the two together.
    static let hint = "Turn one on in Settings › Providers."
    /// The menu bar tooltip's whole usage part.
    static let tooltip = "Omelette — all providers are off. Turn one on in Settings › Providers."
    /// The floating window's line: the fact and where to change it.
    static var sentence: String { "\(title). \(hint)" }
    /// The popover's link to the switches.
    static let button = "Open Settings › Providers"
    /// The widget's line. A widget sits on the desktop, away from the app, so it names
    /// whose Settings.
    static let widget = "All providers are off. Turn one on in Omelette's Settings › Providers."
}
