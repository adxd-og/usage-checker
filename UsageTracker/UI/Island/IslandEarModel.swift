import Combine
import Foundation

/// The ears as they are now on every island display, keyed by display id (notch-island spec
/// 2026-10-29 § 3.6; spec 2026-11-03 § Ears and hint): re-read when the app's state changes and
/// reported only when they moved. No timer: closed, the ears add no wakeup (§ 3.8). What is read
/// comes in as a closure; `IslandEarRules` decides.
@MainActor
final class IslandEarModel {
    private(set) var ears: [UInt32: IslandEars] = [:]
    var onChange: (@MainActor ([UInt32: IslandEars]) -> Void)?

    private let read: @MainActor () -> [UInt32: IslandEars]
    private var signals: AnyCancellable?

    init(read: @escaping @MainActor () -> [UInt32: IslandEars]) {
        self.read = read
    }

    func refresh() {
        let next = read()
        guard next != ears else { return }
        ears = next
        onChange?(next)
    }

    /// The displays changed (a lid opened, a display gained or lost its island): the ears are read
    /// again, with no change of state to signal it, before the windows are placed.
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
