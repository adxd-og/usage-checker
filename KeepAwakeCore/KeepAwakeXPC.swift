import Foundation

/// The XPC contract between the app and the omelette-keepawake daemon (plan D6). An explicit
/// ObjC name so both modules register the same protocol; the reply is JSON
/// (`KeepAwakeCoding.encode(KeepAwakeReply)`), not a class, so the interface needs no class
/// allow-list. The selectors must stay backward compatible across versions: an armed daemon
/// keeps running its old binary after an app update (D12).
@objc(OMKeepAwakeXPCProtocol)
protocol KeepAwakeXPCProtocol {
    func arm(seconds: Double, floorEnabled: Bool, withReply reply: @escaping @Sendable (Data) -> Void)
    func disarm(withReply reply: @escaping @Sendable (Data) -> Void)
    func setFloor(enabled: Bool, withReply reply: @escaping @Sendable (Data) -> Void)
    func state(withReply reply: @escaping @Sendable (Data) -> Void)
    /// The thermal guard's switch (spec 2026-11-19, § Settings), added after 4.3.0. A 4.3.0
    /// daemon's interface does not have it, so the app sends it only to a daemon whose last reply
    /// carried `thermalGuard` (`KeepAwakeReply`); the four above keep their selectors.
    func setThermalGuard(enabled: Bool, withReply reply: @escaping @Sendable (Data) -> Void)
}
