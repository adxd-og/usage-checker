import AppKit
import QuartzCore

/// Something that calls back once per display frame with the time the frame will be on
/// screen: a display link in the app, a fake in the tests.
@MainActor
protocol IslandFrameSource: AnyObject {
    var isRunning: Bool { get }
    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void)
    func stop()
}

/// The island's motion clock (notch-island spec 2026-10-29 § 3.2): passes its source's frames
/// to `onFrame` while motion is wanted and the displays are awake. Closed, open at rest, or
/// with the displays asleep, the island adds no timer and no wake-up (§ 3.8); motion still
/// pending at the wake resumes then. Its policy is tested against a fake source.
@MainActor
final class IslandFrameDriver {
    var onFrame: (@MainActor (TimeInterval) -> Void)?
    private let source: IslandFrameSource
    /// The controller wants frames: the transition has motion pending.
    private var wanted = false
    /// The displays sleep: no frames whatever is wanted.
    private var asleep = false

    init(source: IslandFrameSource) {
        self.source = source
    }

    var isRunning: Bool { source.isRunning }

    /// The time an open or a close acts at: the event's clock, but never behind the last frame
    /// evaluated. A frame's time is when it will be on screen, up to two frames ahead of
    /// `CACurrentMediaTime()`, so an interrupt sets off from what is drawn, never from an
    /// older value.
    nonisolated static func eventTime(now: TimeInterval, lastFrame: TimeInterval?) -> TimeInterval {
        max(now, lastFrame ?? now)
    }

    /// Frames from now on; nothing when they already run.
    func start() {
        wanted = true
        update()
    }

    /// No more frames: the motion is done, or the window is gone.
    func stop() {
        wanted = false
        update()
    }

    /// The displays went to sleep: the frames stop, and what was wanted waits for the wake.
    func displaysSlept() {
        asleep = true
        update()
    }

    /// The displays woke: the frames resume only if motion is still pending.
    func displaysWoke() {
        asleep = false
        update()
    }

    private func update() {
        let run = wanted && !asleep
        if run, !source.isRunning {
            source.start { [weak self] time in
                self?.onFrame?(time)
            }
        } else if !run, source.isRunning {
            source.stop()
        }
    }
}

/// The app's frame source: a display link on the island's hosting view, at the display's rate.
@MainActor
final class DisplayLinkFrameSource: NSObject, IslandFrameSource {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var tick: (@MainActor (TimeInterval) -> Void)?

    init(view: NSView) {
        self.view = view
        super.init()
    }

    var isRunning: Bool { link != nil }

    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void) {
        guard link == nil, let view else { return }
        self.tick = tick
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
    }

    /// `targetTimestamp`: when this frame will be displayed, in `CACurrentMediaTime`'s base.
    @objc private func step(_ link: CADisplayLink) {
        tick?(link.targetTimestamp)
    }
}
