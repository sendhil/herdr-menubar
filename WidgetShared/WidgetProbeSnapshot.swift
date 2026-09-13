import Foundation

struct WidgetProbeSnapshot: Codable, Equatable, Sendable {
    static let freshnessInterval: TimeInterval = 90
    let schemaVersion: Int
    let generation: UUID
    let sequence: Int
    let writtenAt: Date

    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(writtenAt)
        return age >= 0 && age < Self.freshnessInterval
    }
}
