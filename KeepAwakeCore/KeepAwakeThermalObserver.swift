import Foundation

/// `ProcessInfo.thermalStateDidChangeNotification` on `center`, handed to `onChange` on the
/// posting thread, once per post (thermal guard spec 2026-11-19, § Daemon). It observes from
/// its creation until it is released, so the daemon keeps it for the life of the process, as
/// it keeps the power observer.
final class KeepAwakeThermalObserver {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, onChange: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            onChange()
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
