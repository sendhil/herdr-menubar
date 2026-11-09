import Foundation

/// Declaration order is the menu's session sort order.
enum BackendKind: String, Codable, Sendable, CaseIterable {
    case herdr
    case rex

    var displayName: String {
        switch self {
        case .herdr: "Herdr"
        case .rex: "Rex"
        }
    }

    var sortIndex: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// States that notify when `notifyStates.<backend>` is absent.
    var defaultNotifyStates: Set<AttentionState> {
        switch self {
        case .herdr: [.blocked, .done]
        case .rex: [.blocked, .error, .done]
        }
    }
}

struct AgentSessionKey: Hashable, Sendable {
    let backend: BackendKind
    /// Herdr: "default" or "named:<name>"; Rex: session_id.
    let rawID: String
}

extension AgentSessionKey {
    private static let herdrDefaultRawID = "default"
    private static let herdrNamedPrefix = "named:"

    init(herdr sessionID: SessionID) {
        switch sessionID {
        case .default:
            self.init(backend: .herdr, rawID: Self.herdrDefaultRawID)
        case .named(let name):
            self.init(backend: .herdr, rawID: Self.herdrNamedPrefix + name)
        }
    }

    /// The Herdr session this key names; nil for other backends and malformed raw IDs.
    var herdrSessionID: SessionID? {
        guard backend == .herdr else { return nil }
        if rawID == Self.herdrDefaultRawID { return .default }
        guard rawID.hasPrefix(Self.herdrNamedPrefix) else { return nil }
        let name = String(rawID.dropFirst(Self.herdrNamedPrefix.count))
        return name.isEmpty ? nil : .named(name)
    }
}

struct AgentSessionDescriptor: Identifiable, Equatable, Sendable {
    let key: AgentSessionKey
    let displayName: String
    var id: AgentSessionKey { key }
}

extension AgentSessionDescriptor {
    init(herdr descriptor: SessionDescriptor) {
        self.init(key: AgentSessionKey(herdr: descriptor.id), displayName: descriptor.displayName)
    }
}

struct AgentTarget: Hashable, Sendable {
    let session: AgentSessionKey
    /// Herdr: pane_id; Rex: block_id.
    let paneID: String
}

/// Replaced the Herdr-only notification selection target type everywhere in step 1.
/// Equality and hashing use `target` only; the display name is a message hint, refreshed from
/// the store's current descriptor or the raw Herdr session ID when either exists.
struct SelectionTarget: Hashable, Sendable {
    let target: AgentTarget
    let sessionDisplayName: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(target)
    }

    static func herdr(_ sessionID: SessionID, paneID: String) -> SelectionTarget {
        SelectionTarget(
            target: AgentTarget(session: AgentSessionKey(herdr: sessionID), paneID: paneID),
            sessionDisplayName: sessionID.displayName
        )
    }
}

enum AttentionState: String, Sendable {
    case blocked
    case error
    case done
}

enum RowState: Equatable, Sendable {
    /// NEEDS ATTENTION; counted in the badge.
    case attention(AttentionState)
    /// WORKING.
    case working
}

/// Opaque to the store.
struct SeenToken: Hashable, Sendable {
    let marks: Set<String>
}

/// A final row: already seen-filtered and ranked by its backend.
struct AgentRow: Identifiable, Equatable, Sendable {
    let target: AgentTarget
    /// Primary label (Herdr: workspace/tab/pane label).
    let displayLabel: String
    let agentLabel: String?
    let state: RowState
    /// Full secondary line built by the backend (Herdr: "status · agentLabel").
    let subtitle: String
    let seenToken: SeenToken?

    var id: AgentTarget { target }

    var visibleLabel: String {
        guard let agentLabel, agentLabel != displayLabel else { return displayLabel }
        return "\(displayLabel) · \(agentLabel)"
    }

    /// blocked, error, done, then label.
    static func attentionOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsRank = lhs.attentionRank
        let rhsRank = rhs.attentionRank
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return labelOrder(lhs, rhs)
    }

    static func labelOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let lhsLabel = lhs.displayLabel.folding(options: [.caseInsensitive], locale: locale)
        let rhsLabel = rhs.displayLabel.folding(options: [.caseInsensitive], locale: locale)
        if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
        return lhs.target.paneID < rhs.target.paneID
    }

    private var attentionRank: Int {
        switch state {
        case .attention(.blocked): 0
        case .attention(.error): 1
        case .attention(.done): 2
        case .working: 3
        }
    }
}

/// Coordinator input; never seen-filtered.
struct AttentionRecord: Equatable, Sendable {
    let target: AgentTarget
    /// Herdr: ""; Rex: record id.
    let recordID: String
    /// Herdr: 0; Rex: record epoch.
    let epoch: Int
    let state: AttentionState
    let visibleLabel: String
    /// Sanitized; Rex only.
    let message: String?
}

/// What Clear Finished would dismiss in a session: any settled, unseen `done` or `error` record
/// of a placed block, including records that do not decide the block's row. Rex only; Herdr
/// clears `done` itself and always reports `.none`.
struct ClearableRecords: Equatable, Sendable {
    var done = false
    var error = false

    static let none = ClearableRecords()

    var isEmpty: Bool { !done && !error }

    func merged(with other: ClearableRecords) -> ClearableRecords {
        ClearableRecords(done: done || other.done, error: error || other.error)
    }
}

struct BackendSnapshot: Equatable, Sendable {
    let rows: [AgentRow]
    /// In delivery order (Herdr: label order).
    let attention: [AttentionRecord]
    let clearable: ClearableRecords

    init(rows: [AgentRow], attention: [AttentionRecord], clearable: ClearableRecords = .none) {
        self.rows = rows
        self.attention = attention
        self.clearable = clearable
    }

    static let empty = BackendSnapshot(rows: [], attention: [])
}

enum BackendEvent: Equatable, Sendable {
    /// Complete session set.
    case discovery([AgentSessionDescriptor])
    case connected(AgentSessionDescriptor, BackendSnapshot)
    case snapshot(AgentSessionKey, BackendSnapshot)
    case descriptorChanged(AgentSessionDescriptor)
    case sessionUnavailable(AgentSessionKey, String)
    case removed(AgentSessionKey)
    /// Whole backend down; history kept.
    case backendUnavailable(String)
    /// Not installed or disabled.
    case backendHidden
}

/// The message is final, user-facing text.
enum FocusError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        }
    }
}

protocol AgentBackend: Sendable {
    var kind: BackendKind { get }
    func events() async -> AsyncStream<BackendEvent>
    /// Starts discovery and event delivery. May await brief setup (HerdrBackend awaits its
    /// supervisor's start); AgentStore starts backends sequentially, so keep this short and
    /// leave long-running work to tasks.
    func start() async
    func stop() async
    func retryUnavailable() async
    /// Cancellable.
    func focusServer(_ target: AgentTarget) async throws
    /// nil = success, else a partial-focus message.
    func activate(_ target: AgentTarget) async -> String?
    /// Called after a completed `focusServer`.
    func refreshAfterSelection(_ target: AgentTarget) async
    func markSeen(_ token: SeenToken) async
    func clearFinished() async
    func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool
}
