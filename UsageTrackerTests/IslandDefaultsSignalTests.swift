import Combine
import XCTest
@testable import Omelette

/// Defaults are written off the main thread (keep awake's first Apply after an update, Sparkle), and
/// the notification comes on the writing thread. On 2026-11-01 the ears' signal ran a main-actor
/// closure right there, and the app crashed on Apply.
@MainActor
final class IslandDefaultsSignalTests: XCTestCase {
    func testADefaultsWriteOffTheMainThreadReachesTheEarsOnTheMainThread() {
        let center = NotificationCenter()
        let heard = expectation(description: "heard")
        let signal = IslandController.defaultsWriteSignal(center: center)
            .sink {
                XCTAssertTrue(Thread.isMainThread)
                heard.fulfill()
            }
        DispatchQueue.global(qos: .userInitiated).async {
            center.post(name: UserDefaults.didChangeNotification, object: nil)
        }
        wait(for: [heard], timeout: 5)
        signal.cancel()
    }
}
