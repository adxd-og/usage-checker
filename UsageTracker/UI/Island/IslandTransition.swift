import SwiftUI

/// The island's open and close in time (notch-island spec 2026-10-29 § 3.2, § 3.9): closed →
/// opening → open → closing → closed, on a clock the caller injects. It holds the shape's
/// spring (`progress(at:)`) and the stage the views show: the content in after the shape and
/// out before it, clickable and read by VoiceOver only once its entrance has finished, the
/// whole island cross-faded under Reduce Motion.
///
/// Every completion (the island shown, the content in, the open done, the shrink, the close
/// done) is a deadline this value holds for the current open or close. An open or a close
/// replaces them, so a completion from before an interrupt can never fire: a closing
/// island's content is never revived, and a reopened island is never ended by the close it
/// interrupted. `open`, `close` and `advance` each first apply the deadlines due by their
/// own time, so the answer depends on the times alone, not on which frames came. The open
/// completes on the first call after the entrance's fades have run their course from the
/// call they began on, never from the open's own time. Nothing outside (a timer, an
/// animation's completion) changes the phase. Pure.
struct IslandTransition: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case closed
        case opening
        case open
        case closing
    }

    /// What the views show: the targets the content and the window animate to.
    struct Stage: Equatable, Sendable {
        /// The content at full opacity and in place; hidden, it is transparent (and on the
        /// island 8 pt low).
        var contentShown: Bool
        /// How the content gets to `contentShown`; nil: at once.
        var contentFade: IslandMotion.Fade?
        /// Hit-testable and exposed to accessibility: only while open (§ 3.2).
        var interactive: Bool
        /// The whole window's opacity target: Reduce Motion's cross-fade.
        var islandShown: Bool
        /// How the window gets to `islandShown`; nil: at once.
        var islandFade: IslandMotion.Fade?

        static let closed = Stage(
            contentShown: false, contentFade: nil, interactive: false, islandShown: false, islandFade: nil
        )
    }

    /// How an open applies to the island as it is.
    enum OpenRoute: Equatable, Sendable {
        /// Closed: placed, then opened from the notch.
        case fresh
        /// Closing on the display the open asks for: turned around from where it is.
        case reverse
        /// Open, or closing on another display: closed at once, then opened afresh there.
        case moveAndOpen
    }

    private(set) var phase: Phase = .closed
    /// The motion of the current or last open or close.
    private(set) var style: IslandMotion.Style = .spring
    private(set) var stage: Stage = .closed
    private var shape: IslandSpringTrack = .resting(at: 0)
    // The current open's or close's deadlines; nil once passed or not part of it.
    private var islandInAt: TimeInterval?
    private var contentInAt: TimeInterval?
    /// When the entrance ends: set on the call each of its fades begins on, never from the
    /// open's own time, so a late first frame cannot expose content that has not appeared.
    private var openDoneAt: TimeInterval?
    private var shrinkAt: TimeInterval?
    private var closeDoneAt: TimeInterval?

    init() {}

    /// Opening or open. A closing island counts as closed: an entry turns it around.
    var isOpen: Bool { phase == .opening || phase == .open }

    /// Whether the clock must keep ticking: a deadline ahead, or the shape still moving.
    /// Closed, and open at rest, the island needs no frames (§ 3.8).
    var needsFrames: Bool {
        switch phase {
        case .closed: return false
        case .opening, .closing: return true
        case .open: return shape.isMoving
        }
    }

    /// The shape at `time`: 0 the notch, 1 open, past 1 while the open spring overshoots.
    func progress(at time: TimeInterval) -> Double {
        shape.value(at: time)
    }

    /// A plain key aimed at the island while it closes (Esc, typing) goes nowhere: its content
    /// is leaving and no longer interactive (§ 3.2; the key rule is plan M8), and a second Esc
    /// would beep. A key with ⌘ is a shortcut (⌘Q) and goes on. Another window's keys are its
    /// own.
    func swallowsKey(inIsland: Bool, command: Bool) -> Bool {
        phase == .closing && inIsland && !command
    }

    static func route(phase: Phase, sameDisplay: Bool) -> OpenRoute {
        switch phase {
        case .closed: return .fresh
        case .closing: return sameDisplay ? .reverse : .moveAndOpen
        case .opening, .open: return .moveAndOpen
        }
    }

    /// What an open does with the keyboard (§ 3.1, Focus).
    enum KeyAction: Equatable, Sendable {
        /// A click entry: the island becomes key.
        case makeKey
        /// An ear: the island comes forward and the keyboard stays where it is.
        case orderFront
        /// An ear turning around an island that holds key from an earlier click: forward, and
        /// the keyboard back to the app behind.
        case handBack
    }

    /// Every open, a reversal included, takes its entry's key policy: an entry that gives key
    /// takes it; one that does not leaves the keyboard with the app behind, handing it back
    /// when the island still holds it.
    static func keyAction(entryBecomesKey: Bool, islandIsKey: Bool) -> KeyAction {
        if entryBecomesKey { return .makeKey }
        return islandIsKey ? .handBack : .orderFront
    }

    /// Opens with `style` at `now`, after applying what was due by then; nothing when already
    /// opening or open. From closing it turns around: the shape springs back from its value and
    /// velocity at `now`, and the content comes back at once when the shape had not started to
    /// shrink, else after the usual head start. The changes show from the next `advance`, the
    /// clock's next frame.
    mutating func open(style: IslandMotion.Style, at now: TimeInterval) {
        advance(to: now)
        guard !isOpen else { return }
        // Closing, but the shape has not started to shrink: it is still open.
        let shapeStillOpen = phase == .closing && shrinkAt != nil
        self.style = style
        phase = .opening
        shrinkAt = nil
        closeDoneAt = nil
        openDoneAt = nil
        stage.interactive = false
        islandInAt = now
        switch style {
        case .crossFade, .contentOnly:
            shape = .resting(at: 1)
            contentInAt = now
        case .spring:
            shape = shape.retargeted(to: 1, with: IslandMotion.open, at: now)
            contentInAt = shapeStillOpen ? now : now + IslandMotion.contentDelay
        }
    }

    /// Closes with `style` at `now`, after applying what was due by then; nothing when closed
    /// or already closing. The content stops being clickable and readable at once. The island:
    /// the content fades out, then the shape shrinks from where it is (at once when the
    /// content had not come in yet). The panel: its content fades out. Reduce Motion: the
    /// whole island fades, its shape frozen where it is.
    mutating func close(style: IslandMotion.Style, at now: TimeInterval) {
        advance(to: now)
        guard isOpen else { return }
        self.style = style
        phase = .closing
        islandInAt = nil
        contentInAt = nil
        openDoneAt = nil
        stage.interactive = false
        switch style {
        case .crossFade:
            // Nothing grows or shrinks while the island fades.
            shape = .resting(at: shape.value(at: now))
            stage.islandShown = false
            stage.islandFade = IslandMotion.islandFade(style: style)
            closeDoneAt = now + IslandMotion.reducedFade
        case .contentOnly:
            stage.contentShown = false
            stage.contentFade = IslandMotion.contentFade(showing: false, style: style)
            closeDoneAt = now + IslandMotion.contentOut
        case .spring:
            if stage.contentShown {
                stage.contentShown = false
                stage.contentFade = IslandMotion.contentFade(showing: false, style: style)
                shrinkAt = now + IslandMotion.contentOut
            } else {
                shape = shape.retargeted(to: 0, with: IslandMotion.close, at: now)
            }
        }
    }

    /// Applies every deadline due by `now`, then lets the shape come to rest. A `now` before
    /// a deadline changes nothing, so a late or early frame is harmless.
    mutating func advance(to now: TimeInterval) {
        switch phase {
        case .closed:
            return
        case .opening:
            if let due = islandInAt, now >= due {
                islandInAt = nil
                stage.islandShown = true
                stage.islandFade = IslandMotion.islandFade(style: style)
                entranceRuns(until: now + (stage.islandFade?.duration ?? 0))
            }
            if let due = contentInAt, now >= due {
                contentInAt = nil
                stage.contentShown = true
                stage.contentFade = IslandMotion.contentFade(showing: true, style: style)
                entranceRuns(until: now + (stage.contentFade?.duration ?? 0))
            }
            if islandInAt == nil, contentInAt == nil, let due = openDoneAt, now >= due {
                openDoneAt = nil
                phase = .open
                stage.interactive = true
            }
        case .open:
            break
        case .closing:
            if let due = shrinkAt, now >= due {
                shrinkAt = nil
                // From the moment it was due, so the curve does not depend on the frame rate.
                shape = shape.retargeted(to: 0, with: IslandMotion.close, at: due)
            }
            if let due = closeDoneAt, now >= due {
                reset()
                return
            }
            if style == .spring, shrinkAt == nil, shape.to == 0, shape.isAtRest(at: now) {
                reset()
                return
            }
        }
        if shape.isMoving, shape.isAtRest(at: now) {
            shape = .resting(at: shape.to)
        }
    }

    /// Closed at once, from any phase: the close's last frame, or a move to another display.
    mutating func reset() {
        self = IslandTransition()
    }

    /// The entrance lasts at least until `time`: a fade began on this call and runs that long.
    private mutating func entranceRuns(until time: TimeInterval) {
        openDoneAt = max(openDoneAt ?? time, time)
    }
}
