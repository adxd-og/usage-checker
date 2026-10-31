import Combine
import Foundation

/// The ears as they are now (notch-island spec 2026-10-29 § 3.6): re-read when the app's state changes
/// and reported only when they moved. No timer: closed, the ears add no wakeup (§ 3.8). What is read
/// comes in as a closure; `IslandEarRules` decides.
@MainActor
final class IslandEarModel {
    private(set) var ears = IslandEars.none
    var onChange: (@MainActor (IslandEars) -> Void)?

    private let read: @MainActor () -> IslandEars
    private var signals: AnyCancellable?

    init(read: @escaping @MainActor () -> IslandEars) {
        self.read = read
    }

    func refresh() {
        let next = read()
        guard next != ears else { return }
        ears = next
        onChange?(next)
    }

    /// The displays changed (a lid opened, a notched display came or went): the ears are read again,
    /// with no change of state to signal it, before the window is placed.
    func displaysChanged(place: () -> Void) {
        refresh()
        place()
    }

    /// Re-reads on every value of `signal`. `@Published` sends before the value lands, so the read
    /// waits one turn of the main queue.
    func watch<P: Publisher>(_ signal: P) where P.Failure == Never {
        signals = signal
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
    }
}
