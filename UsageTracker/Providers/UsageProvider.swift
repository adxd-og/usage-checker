import Foundation

protocol UsageProvider: Sendable {
    var serviceID: String { get }
    func fetch() async -> ServiceSnapshot
}
