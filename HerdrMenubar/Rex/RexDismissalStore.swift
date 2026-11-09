import Foundation

/// A Rex record the user saw or cleared, by stable server identity: the record key plus the
/// state and `updated_at` it had. It hides that record in later launches until the server
/// re-emits it (a new `updated_at` or state). Never keyed by the in-memory epoch.
struct RexDismissal: Codable, Hashable, Sendable {
    let sessionID: String
    let blockID: String
    /// `""` for the block's root record.
    let recordID: String
    let state: String
    /// `updated_at` in microseconds since the Unix epoch.
    let updatedAt: Int64

    var key: RexRecordKey { RexRecordKey(sessionID: sessionID, blockID: blockID, recordID: recordID) }
}

/// Where RexBackend keeps dismissals between launches. Loaded at `start()`, saved when they change.
protocol RexDismissalStoring: Sendable {
    /// Oldest first. `nil` when nothing is stored yet (or it is unreadable): the reducer then
    /// seeds dismissals from the first snapshot. A stored empty list is `[]`.
    func load() -> [RexDismissal]?
    func save(_ dismissals: [RexDismissal])
}

/// Keeps nothing: dismissals last for the backend's run only, and nothing is seeded. The default,
/// so tests and previews never touch real preferences.
struct NoRexDismissalStore: RexDismissalStoring {
    func load() -> [RexDismissal]? { [] }
    func save(_ dismissals: [RexDismissal]) {}
}

/// JSON-encoded under `rexDismissedRecords`. Absent or unreadable data loads as `nil`.
final class UserDefaultsRexDismissalStore: RexDismissalStoring, @unchecked Sendable {
    // UserDefaults is thread-safe; it is just not annotated Sendable.
    static let key = "rexDismissedRecords"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> [RexDismissal]? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode([RexDismissal].self, from: data)
    }

    func save(_ dismissals: [RexDismissal]) {
        guard let data = try? JSONEncoder().encode(dismissals) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
