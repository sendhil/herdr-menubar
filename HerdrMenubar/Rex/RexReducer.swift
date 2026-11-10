import Foundation

// The pure, synchronous core of RexBackend: watcher lines in, BackendEvents out.
// RexBackend (an actor) owns one value, feeds it lines tagged with the watcher generation, and
// drives time through `now`/`tick(now:)`. Nothing here performs I/O or reads a clock.

/// Identifies one program-status record: `(session_id, block_id, record id)`.
struct RexRecordKey: Hashable, Sendable {
    let sessionID: String
    let blockID: String
    /// `""` for the block's root record.
    let recordID: String
}

/// Why the watcher must be treated as failed. RexBackend terminates the process, emits
/// `.backendUnavailable(reason)`, and restarts with backoff. Only whole-watcher failures count:
/// a block or session that could not be read is logged and skipped, never a failure.
enum RexWatcherFailure: Equatable, Sendable {
    case snapshotError(String)
    case encodeError(String)

    var reason: String {
        switch self {
        case .snapshotError(let message): "Rex watcher snapshot failed: \(message)"
        case .encodeError(let message): "Rex watcher could not encode a line: \(message)"
        }
    }

    /// The script reports `snapshot_error` and then exits 1 on its own before `snapshot_done`,
    /// which is the spec's "failed candidate" condition. RexBackend may terminate the process
    /// first, so it should mark the CLI candidate failed when this is true rather than waiting
    /// for the exit status.
    var marksCandidateFailed: Bool {
        if case .snapshotError = self { return true }
        return false
    }
}

struct RexReducerOutput: Equatable, Sendable {
    var events: [BackendEvent] = []
    /// Non-nil: the watcher generation has failed. No further lines of it should be applied.
    var failure: RexWatcherFailure?
    /// Diagnostics for the log (errors after `snapshot_done`, unknown line kinds). Not user-facing.
    var logMessages: [String] = []
}

struct RexReducer: Sendable {
    // MARK: Backend-level state (persists across generations; cleared by `reset()`)

    private struct LastKnown: Sendable {
        var state: String
        var updatedAt: Int64?
        var epoch: Int
        /// When the current epoch was assigned; it settles `settleDelay` later.
        var epochStart: ContinuousClock.Instant
    }

    /// How long an attention epoch must exist before it reaches the coordinator.
    static let settleDelay: Duration = .milliseconds(1500)

    /// Last value handed out by the backend-wide epoch counter. Never decreases, not even on
    /// `reset()`, so an epoch is never reused.
    private var epochCounter = 0
    private var lastKnown: [RexRecordKey: LastKnown] = [:]
    /// Per root record: the distinct results (epoch + exact `updated_at`) observed this run for
    /// each millisecond. More than one for a millisecond makes a receipt match ambiguous.
    private struct ResultID: Hashable, Sendable { let epoch: Int; let updatedAt: Int64 }
    private var observedResults: [RexRecordKey: [Int64: Set<ResultID>]] = [:]
    private static let observedResultCap = 4000
    /// Seen marks: the epoch of each record the user has seen. A `done`/`error` record is hidden
    /// iff its mark equals its current epoch. Pruned when the record gets a new epoch or is dropped.
    private var seenMarks: [RexRecordKey: Int] = [:]
    /// Settled epochs (flap protection). A record is in `attention` iff its current epoch is here.
    private var settled: [RexRecordKey: Int] = [:]
    /// Persisted dismissals by record key: the state and `updated_at` a seen or cleared record had.
    /// A record whose new epoch has exactly that state and `updated_at` starts out seen, so a
    /// dismissal survives relaunches. Loaded from and saved to a `RexDismissalStoring` by
    /// RexBackend. `order` ranks them for the cap (higher is newer).
    private struct Dismissed: Sendable {
        var state: String
        var updatedAt: Int64
        var order: Int
    }

    /// At most this many dismissals are kept; the oldest go first.
    static let dismissalCap = 500

    private var dismissed: [RexRecordKey: Dismissed] = [:]
    private var dismissalOrder = 0
    /// Bumped whenever `dismissals` changes, so RexBackend saves only real changes.
    private(set) var dismissalsRevision = 0
    /// Nothing was stored yet (upgrade or first run): the first successful snapshot dismisses
    /// every settled terminal record it has, so existing results do not flood the badge.
    private var seedsDismissalsAtFirstSnapshot = false
    /// Set at the first successful `snapshot_done` since start, whose records all settle at once.
    private var hasCompletedFirstSnapshot = false

    /// Wall-clock microseconds since the Unix epoch, comparable with `updated_at` (the server
    /// runs on this machine). Read once, at the first successful `snapshot_done`.
    var wallClock: @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000_000).rounded()) }
    /// Records up to this long before the first snapshot still count as possibly new.
    static let lateBaselineTolerance: Int64 = 5_000_000

    /// Blocks and sessions the first successful snapshot could not read. They have no history,
    /// so on their first successful later read (any generation) a record whose `updated_at`
    /// predates the first snapshot (minus the tolerance) is baseline, like the first snapshot's
    /// records: settled at once, never offered for notification, and dismissed if seeding was
    /// pending then. Newer records behave normally.
    private struct LateBaseline: Sendable {
        var cutoff: Int64
        var seeds: Bool
        var blocks: Set<BlockKey>
        var sessions: Set<String>
    }

    private var lateBaseline: LateBaseline?
    /// Baseline epochs that are settled but kept out of `attention` (no notification).
    private var silentEpochs: [RexRecordKey: Int] = [:]
    /// Sessions the store has been told about with `.connected` and not yet `.removed`.
    private(set) var sessionsKnownToStore: Set<String> = []

    // MARK: Per-generation state (cleared by `beginGeneration`)

    private struct SessionState: Sendable {
        var label: String?
        var view: RexSessionView?
    }

    private struct BlockKey: Hashable, Sendable {
        let sessionID: String
        let blockID: String
    }

    private(set) var generation: Int?
    private(set) var isSnapshotDone = false
    private var sessions: [String: SessionState] = [:]
    /// Current records per block, from the latest read in this generation.
    private var blockRecords: [BlockKey: [RexRecord]] = [:]
    /// What the store last received per session in this generation, to emit only real changes.
    private var lastEmitted: [String: BackendSnapshot] = [:]
    /// Blocks and sessions whose reads failed before `snapshot_done`. Their last-known records
    /// survive the snapshot's pruning, so a later successful read compares against history.
    private var unreadBlocks: Set<BlockKey> = []
    private var unreadSessions: Set<String> = []

    init() {}

    // MARK: Lifecycle

    /// Starts a watcher generation: forgets sessions, views, and current records. Last-known
    /// records, epochs, and the sessions known to the store persist.
    mutating func beginGeneration(_ generation: Int) {
        self.generation = generation
        isSnapshotDone = false
        sessions = [:]
        blockRecords = [:]
        lastEmitted = [:]
        unreadBlocks = []
        unreadSessions = []
    }

    /// The watcher generation failed or exited: ignore its remaining lines and emit nothing (from
    /// lines, ticks, `markSeen`, or `clearFinished`) until the next generation's `snapshot_done`.
    /// State changes made meanwhile (settling, seen marks) are reported by that `.connected`.
    mutating func endGeneration() {
        generation = nil
        isSnapshotDone = false
    }

    /// `stop()`: forget everything except the epoch counter's value (dismissals too: `start()`
    /// reloads them). The next generation's first successful snapshot is a fresh "first".
    mutating func reset() {
        let counter = epochCounter, wallClock = wallClock
        self = RexReducer()
        epochCounter = counter
        self.wallClock = wallClock
    }

    // MARK: Lines

    /// Applies one decoded watcher line. Lines of any other generation are ignored.
    mutating func apply(_ line: RexWatcherLine, generation: Int, now: ContinuousClock.Instant) -> RexReducerOutput {
        var output = RexReducerOutput()
        guard generation == self.generation else { return output }

        // Settle what is already due first, as its own snapshot: the line may replace a record
        // whose deadline passed while the settle timer was late, and that settle must not be lost.
        emitChangedSnapshots(for: settleDue(now: now), into: &output)
        var affected: Set<String> = []
        switch line {
        case .session(let id, let label):
            if sessions[id] == nil { sessions[id] = SessionState(label: label) }
            else { sessions[id]?.label = label }

        case .view(let view):
            guard sessions[view.sessionID] != nil else { break }
            let oldName = displayName(view.sessionID)
            sessions[view.sessionID]?.view = view
            if let label = view.sessionLabel { sessions[view.sessionID]?.label = label }
            emitDescriptorChange(view.sessionID, oldName: oldName, into: &output)
            affected.insert(view.sessionID)

        case .block(let read):
            guard sessions[read.sessionID] != nil else { break }
            applyRead(read, now: now)
            affected.insert(read.sessionID)

        case .blockClosed(let sessionID, let blockID):
            blockRecords[BlockKey(sessionID: sessionID, blockID: blockID)] = nil
            dropLastKnown { $0.sessionID == sessionID && $0.blockID == blockID }
            removeDismissals { $0.sessionID == sessionID && $0.blockID == blockID }
            forgetLateBaseline { $0.sessionID == sessionID && $0.blockID == blockID }
            affected.insert(sessionID)

        case .sessionDestroyed(let sessionID):
            sessions[sessionID] = nil
            blockRecords = blockRecords.filter { $0.key.sessionID != sessionID }
            dropLastKnown { $0.sessionID == sessionID }
            removeDismissals { $0.sessionID == sessionID }
            forgetLateBaseline(where: { $0.sessionID == sessionID }, session: sessionID)
            if isSnapshotDone, sessionsKnownToStore.remove(sessionID) != nil {
                lastEmitted[sessionID] = nil
                output.events.append(.removed(key(sessionID)))
            }

        case .sessionCreated(let sessionID, let label):
            if sessions[sessionID] != nil {
                let oldName = displayName(sessionID)
                if let label { sessions[sessionID]?.label = label }
                emitDescriptorChange(sessionID, oldName: oldName, into: &output)
            } else {
                sessions[sessionID] = SessionState(label: label)
                if isSnapshotDone {
                    sessionsKnownToStore.insert(sessionID)
                    lastEmitted[sessionID] = .empty
                    output.events.append(.connected(descriptor(sessionID), .empty))
                }
            }
            affected.insert(sessionID)

        case .snapshotDone:
            guard !isSnapshotDone else { break }
            completeSnapshot(into: &output)

        case .heartbeat:
            break

        case .statusError(let sessionID, let blockID, let message):
            output.logMessages.append("Rex status read failed for \(blockID) in \(sessionID): \(message)")
            if !isSnapshotDone { unreadBlocks.insert(BlockKey(sessionID: sessionID, blockID: blockID)) }

        case .viewError(let sessionID, let message):
            output.logMessages.append("Rex view read failed for \(sessionID): \(message)")

        case .listBlocksError(let sessionID, let message):
            output.logMessages.append("Rex block list failed for \(sessionID): \(message)")
            if !isSnapshotDone { unreadSessions.insert(sessionID) }

        case .snapshotError(let message):
            output.failure = .snapshotError(message)

        case .encodeError(let message):
            output.failure = .encodeError(message)

        case .unknown(let type):
            output.logMessages.append("Ignoring unknown Rex watcher line type \(type)")
        }

        emitChangedSnapshots(for: affected, into: &output)
        return output
    }

    // MARK: Flap protection

    /// When the earliest unsettled attention epoch settles; nil when nothing is pending.
    /// RexBackend schedules one timer for this instant and calls `tick(now:)` when it fires.
    var nextSettleDeadline: ContinuousClock.Instant? {
        lastKnown.filter { isPendingSettle($0.key, $0.value) }.map { $0.value.epochStart + Self.settleDelay }.min()
    }

    /// Settles every attention epoch that has existed for `settleDelay`, and returns `.snapshot`
    /// events for the sessions whose attention changed (none before `snapshot_done`).
    mutating func tick(now: ContinuousClock.Instant) -> [BackendEvent] {
        let affected = settleDue(now: now)
        var output = RexReducerOutput()
        emitChangedSnapshots(for: affected, into: &output)
        return output.events
    }

    private func isPendingSettle(_ key: RexRecordKey, _ known: LastKnown) -> Bool {
        settled[key] != known.epoch
            && RexProgramState(rawValue: known.state).flatMap(RexRows.attentionState) != nil
    }

    private mutating func settleDue(now: ContinuousClock.Instant) -> Set<String> {
        var affected: Set<String> = []
        for (key, known) in lastKnown where isPendingSettle(key, known) && known.epochStart + Self.settleDelay <= now {
            settled[key] = known.epoch
            affected.insert(key.sessionID)
        }
        return affected
    }

    private mutating func settleImmediately(where shouldSettle: (RexRecordKey) -> Bool) {
        for (key, known) in lastKnown where shouldSettle(key) {
            settled[key] = known.epoch
        }
    }

    // MARK: Seen-state

    /// Replaces the dismissals with `list` (oldest first; the newest `dismissalCap` are kept) and
    /// hides any known record they match. `nil` (nothing stored yet) seeds them at the first
    /// successful snapshot instead. Called by RexBackend at `start()`.
    mutating func loadDismissals(_ list: [RexDismissal]?) {
        dismissed = [:]
        seedsDismissalsAtFirstSnapshot = list == nil
        for dismissal in (list ?? []).suffix(Self.dismissalCap) {
            dismissalOrder += 1
            dismissed[dismissal.key] = Dismissed(state: dismissal.state, updatedAt: dismissal.updatedAt, order: dismissalOrder)
        }
        for (key, known) in lastKnown where matchesDismissal(key, state: known.state, updatedAt: known.updatedAt) {
            seenMarks[key] = known.epoch
        }
    }

    /// The dismissals to persist, oldest first.
    var dismissals: [RexDismissal] {
        dismissed.sorted { $0.value.order < $1.value.order }.map { key, value in
            RexDismissal(sessionID: key.sessionID, blockID: key.blockID, recordID: key.recordID,
                         state: value.state, updatedAt: value.updatedAt)
        }
    }

    /// Marks every `(record key, epoch)` in the token whose epoch is still current. Returns
    /// `.snapshot` events for sessions whose rows changed (none before `snapshot_done`).
    mutating func markSeen(_ token: SeenToken) -> [BackendEvent] {
        var affected: Set<String> = []
        for (key, known) in lastKnown where Self.isTerminal(known.state) && seenMarks[key] != known.epoch {
            guard token.marks.contains(Self.mark(key, epoch: known.epoch)) else { continue }
            dismiss(key, known)
            affected.insert(key.sessionID)
        }
        var output = RexReducerOutput()
        emitChangedSnapshots(for: affected, into: &output)
        return output.events
    }

    /// Passive acknowledgement from Rex's viewed receipts (`nil`: unavailable, change nothing).
    /// Hides a root `done`/`error` result (a settled one, for errors) only when a root receipt for
    /// its block carries exactly the result's current `updated_at` in milliseconds, the result is
    /// unambiguous this run, and the block id is unique. It reuses the seen-mark path, so the
    /// acknowledgement belongs to that epoch alone and a later result shows again.
    mutating func acknowledgeViewedReceipts(_ receipts: [RexViewReceipt]?) -> [BackendEvent] {
        guard let receipts, generation != nil, isSnapshotDone else { return [] }
        var wanted: [String: Set<Int64>] = [:]
        for receipt in receipts where receipt.recordID.isEmpty {
            wanted[receipt.blockID, default: []].insert(receipt.millis)
        }
        guard !wanted.isEmpty else { return [] }
        var blockCounts: [String: Int] = [:]
        for key in lastKnown.keys where key.recordID.isEmpty { blockCounts[key.blockID, default: 0] += 1 }
        var affected: Set<String> = []
        for (key, known) in lastKnown
        where key.recordID.isEmpty && Self.isTerminal(known.state) && seenMarks[key] != known.epoch {
            guard let at = known.updatedAt, blockCounts[key.blockID] == 1 else { continue }
            let millis = RexViewReceipt.millis(fromMicroseconds: at)
            guard wanted[key.blockID]?.contains(millis) == true,
                  observedResults[key]?[millis]?.count == 1 else { continue }
            if known.state == RexProgramState.error.rawValue, settled[key] != known.epoch { continue }
            dismiss(key, known)
            affected.insert(key.sessionID)
        }
        var output = RexReducerOutput()
        emitChangedSnapshots(for: affected, into: &output)
        return output.events
    }

    /// True when a receipt could hide something: an unseen root `done`/`error` record exists.
    var hasUnseenRootResults: Bool {
        lastKnown.contains { $0.key.recordID.isEmpty && Self.isTerminal($0.value.state) && seenMarks[$0.key] != $0.value.epoch }
    }

    /// Clear Finished: marks every unseen `done` record, and every unseen `error` record that has
    /// settled (past flap protection), of every placed block. A later epoch shows again.
    mutating func clearFinished() -> [BackendEvent] {
        var affected: Set<String> = []
        for sessionID in sessions.keys {
            for (key, known, _) in clearableRecords(sessionID) where seenMarks[key] != known.epoch {
                dismiss(key, known)
                affected.insert(sessionID)
            }
        }
        var output = RexReducerOutput()
        emitChangedSnapshots(for: affected, into: &output)
        return output.events
    }

    /// The records Clear Finished would dismiss in a session: unseen `done`, and unseen settled
    /// `error`, records of its placed blocks, whether or not they decide the block's row.
    private func clearableRecords(_ sessionID: String) -> [(RexRecordKey, LastKnown, RexProgramState)] {
        var result: [(RexRecordKey, LastKnown, RexProgramState)] = []
        var placed: Set<String> = []
        for block in sessions[sessionID]?.view?.blocks ?? [] where placed.insert(block.blockID).inserted {
            for record in blockRecords[BlockKey(sessionID: sessionID, blockID: block.blockID)] ?? [] {
                guard let state = record.programState, state == .done || state == .error else { continue }
                let key = recordKey(sessionID, block.blockID, record.id)
                guard let known = lastKnown[key], seenMarks[key] != known.epoch else { continue }
                if state == .error, settled[key] != known.epoch { continue }
                result.append((key, known, state))
            }
        }
        return result
    }

    /// Marks the record's current epoch seen and persists it by server identity. A record without
    /// `updated_at` has no stable identity, so it is hidden for this run only.
    private mutating func dismiss(_ key: RexRecordKey, _ known: LastKnown) {
        seenMarks[key] = known.epoch
        setDismissal(key, state: known.state, updatedAt: known.updatedAt, keepOrder: false)
    }

    private func matchesDismissal(_ key: RexRecordKey, state: String, updatedAt: Int64?) -> Bool {
        guard let dismissal = dismissed[key], let updatedAt else { return false }
        return dismissal.state == state && dismissal.updatedAt == updatedAt
    }

    /// Stores (or, with no `updatedAt`, removes) the dismissal for `key`, evicting the oldest
    /// beyond the cap. `keepOrder` refreshes an existing entry without making it newer.
    private mutating func setDismissal(_ key: RexRecordKey, state: String, updatedAt: Int64?, keepOrder: Bool) {
        guard let updatedAt else {
            removeDismissal(key)
            return
        }
        let order: Int
        if keepOrder, let existing = dismissed[key] {
            guard existing.state != state || existing.updatedAt != updatedAt else { return }
            order = existing.order
        } else {
            dismissalOrder += 1
            order = dismissalOrder
        }
        dismissed[key] = Dismissed(state: state, updatedAt: updatedAt, order: order)
        if dismissed.count > Self.dismissalCap,
           let oldest = dismissed.min(by: { $0.value.order < $1.value.order })?.key {
            dismissed[oldest] = nil
        }
        dismissalsRevision += 1
    }

    private mutating func removeDismissal(_ key: RexRecordKey) {
        guard dismissed.removeValue(forKey: key) != nil else { return }
        dismissalsRevision += 1
    }

    /// Number of live seen marks. For tests and diagnostics.
    var seenMarkCount: Int { seenMarks.count }

    private static func isTerminal(_ state: String) -> Bool {
        state == RexProgramState.done.rawValue || state == RexProgramState.error.rawValue
    }

    /// Opaque token element for `(record key, epoch)`.
    private static func mark(_ key: RexRecordKey, epoch: Int) -> String {
        "\(epoch)\u{1F}\(key.sessionID)\u{1F}\(key.blockID)\u{1F}\(key.recordID)"
    }

    // MARK: Queries

    /// The rows and attention records a session would be reported with now.
    func snapshot(forSession sessionID: String) -> BackendSnapshot {
        guard let session = sessions[sessionID], let view = session.view else { return .empty }
        let sessionKey = key(sessionID)
        var rows: [AgentRow] = []
        var attention: [(label: String, record: AttentionRecord)] = []
        var placed: Set<String> = []

        for block in view.blocks where placed.insert(block.blockID).inserted {
            let records = blockRecords[BlockKey(sessionID: sessionID, blockID: block.blockID)] ?? []
            guard !records.isEmpty else { continue }
            let ranked = records.compactMap { record -> RexRankedRecord? in
                guard let known = lastKnown[recordKey(sessionID, block.blockID, record.id)] else { return nil }
                return RexRankedRecord(record: record, epoch: known.epoch)
            }
            let primary = RexRows.primaryLabel(block: block, sessionLabel: session.label)
            var marks: Set<String> = []
            var visible: [RexRankedRecord] = []
            for candidate in ranked {
                let key = recordKey(sessionID, block.blockID, candidate.record.id)
                if Self.isTerminal(candidate.record.state) {
                    marks.insert(Self.mark(key, epoch: candidate.epoch))
                    if seenMarks[key] == candidate.epoch { continue }
                }
                visible.append(candidate)
            }
            if let row = RexRows.row(session: sessionKey, block: block, sessionLabel: session.label,
                                     visibleRecords: visible, seenToken: marks.isEmpty ? nil : SeenToken(marks: marks)) {
                rows.append(row)
            }
            for candidate in ranked {
                let candidateKey = recordKey(sessionID, block.blockID, candidate.record.id)
                guard let state = candidate.record.programState.flatMap(RexRows.attentionState),
                      settled[candidateKey] == candidate.epoch, silentEpochs[candidateKey] != candidate.epoch
                else { continue }
                attention.append((primary, AttentionRecord(
                    target: AgentTarget(session: sessionKey, paneID: block.blockID),
                    recordID: candidate.record.id,
                    epoch: candidate.epoch,
                    state: state,
                    visibleLabel: primary,
                    message: RexText.sanitizedNonEmpty(candidate.record.msg)
                )))
            }
        }

        rows.sort(by: AgentRow.labelOrder)
        let orderedAttention = attention.sorted { lhs, rhs in
            let l = RexRows.foldedLabel(lhs.label), r = RexRows.foldedLabel(rhs.label)
            if l != r { return l < r }
            if lhs.record.target.paneID != rhs.record.target.paneID {
                return lhs.record.target.paneID < rhs.record.target.paneID
            }
            return lhs.record.recordID < rhs.record.recordID
        }.map(\.record)
        var clearable = ClearableRecords.none
        for (_, _, state) in clearableRecords(sessionID) {
            if state == .done { clearable.done = true } else { clearable.error = true }
        }
        return BackendSnapshot(rows: rows, attention: orderedAttention, clearable: clearable)
    }

    /// The descriptor the store would receive for a session of this generation.
    func descriptor(_ sessionID: String) -> AgentSessionDescriptor {
        AgentSessionDescriptor(key: key(sessionID), displayName: displayName(sessionID))
    }

    /// The current epoch of a record, if it is known. For tests and diagnostics.
    func epoch(of key: RexRecordKey) -> Int? {
        lastKnown[key]?.epoch
    }

    // MARK: Reduction

    private mutating func applyRead(_ read: RexBlockRead, now: ContinuousClock.Instant) {
        let records = read.gone ? [] : read.records

        // 1. `via` check: the event saw a state the re-read may have collapsed.
        if let via = read.via, let viaState = via.state, let viaAt = via.updatedAt {
            let key = recordKey(read.sessionID, read.blockID, via.id)
            if let known = lastKnown[key], let knownAt = known.updatedAt, viaAt > knownAt, viaState != known.state {
                setLastKnown(key, state: viaState, updatedAt: viaAt, newEpoch: true, now: now)
            }
        }

        // 2. Re-read: replace the block's records; a new or changed state gets a new epoch.
        var current: [RexRecord] = []
        var seenIDs: Set<String> = []
        for record in records where seenIDs.insert(record.id).inserted {
            current.append(record)
        }
        let lateCutoff = read.gone ? nil : lateBaselineCutoff(for: BlockKey(sessionID: read.sessionID, blockID: read.blockID))
        for record in current {
            let key = recordKey(read.sessionID, read.blockID, record.id)
            let isNew = lastKnown[key] == nil
            let changed = lastKnown[key].map { $0.state != record.state } ?? true
            setLastKnown(key, state: record.state, updatedAt: record.updatedAt, newEpoch: changed, now: now)
            if isNew, let lateCutoff, let at = record.updatedAt, at <= lateCutoff {
                applyLateBaseline(key)
            }
        }
        blockRecords[BlockKey(sessionID: read.sessionID, blockID: read.blockID)] = current

        // 3. Drop records absent from the read. A successful read lacking a record also drops its
        //    dismissal; a `gone` read (a 404, possibly transient) leaves that to `block_closed`.
        dropLastKnown { $0.sessionID == read.sessionID && $0.blockID == read.blockID && !seenIDs.contains($0.recordID) }
        if !read.gone {
            removeDismissals { $0.sessionID == read.sessionID && $0.blockID == read.blockID && !seenIDs.contains($0.recordID) }
        }
    }

    private mutating func setLastKnown(_ key: RexRecordKey, state: String, updatedAt: Int64?, newEpoch: Bool,
                                       now: ContinuousClock.Instant) {
        defer { observeResult(key) }
        if newEpoch || lastKnown[key] == nil {
            epochCounter += 1
            lastKnown[key] = LastKnown(state: state, updatedAt: updatedAt, epoch: epochCounter, epochStart: now)
            settled[key] = nil
            silentEpochs[key] = nil
            // A persisted dismissal of exactly this emission (same state and `updated_at`) keeps
            // it seen across relaunches; any other emission shows and drops the dismissal.
            if matchesDismissal(key, state: state, updatedAt: updatedAt) {
                seenMarks[key] = epochCounter
            } else {
                seenMarks[key] = nil
                removeDismissal(key)
            }
        } else {
            lastKnown[key]?.state = state
            lastKnown[key]?.updatedAt = updatedAt
            // Same epoch, so a seen record stays seen; its dismissal follows the new `updated_at`.
            if let known = lastKnown[key], seenMarks[key] == known.epoch {
                setDismissal(key, state: state, updatedAt: updatedAt, keepOrder: true)
            }
        }
    }

    private mutating func observeResult(_ key: RexRecordKey) {
        guard key.recordID.isEmpty, let known = lastKnown[key], let at = known.updatedAt,
              Self.isTerminal(known.state) else { return }
        if observedResults.count >= Self.observedResultCap, observedResults[key] == nil {
            observedResults = observedResults.filter { lastKnown[$0.key] != nil }
        }
        observedResults[key, default: [:]][RexViewReceipt.millis(fromMicroseconds: at), default: []]
            .insert(ResultID(epoch: known.epoch, updatedAt: at))
    }

    private mutating func dropLastKnown(where shouldDrop: (RexRecordKey) -> Bool) {
        for key in lastKnown.keys where shouldDrop(key) {
            lastKnown[key] = nil
            seenMarks[key] = nil
            settled[key] = nil
            silentEpochs[key] = nil
        }
    }

    /// The baseline cutoff when this read is the first successful one of a block the first
    /// snapshot could not read (the block is then no longer pending); nil otherwise.
    private mutating func lateBaselineCutoff(for block: BlockKey) -> Int64? {
        guard let baseline = lateBaseline else { return nil }
        if lateBaseline?.blocks.remove(block) != nil || baseline.sessions.contains(block.sessionID) {
            return baseline.cutoff
        }
        return nil
    }

    private mutating func applyLateBaseline(_ key: RexRecordKey) {
        guard let known = lastKnown[key] else { return }
        settled[key] = known.epoch
        silentEpochs[key] = known.epoch
        if lateBaseline?.seeds == true, Self.isTerminal(known.state), seenMarks[key] != known.epoch {
            dismiss(key, known)
        }
    }

    private mutating func forgetLateBaseline(where shouldForget: (BlockKey) -> Bool, session: String? = nil) {
        guard var baseline = lateBaseline else { return }
        baseline.blocks = baseline.blocks.filter { !shouldForget($0) }
        if let session { baseline.sessions.remove(session) }
        lateBaseline = baseline
    }

    /// Dismissals go only on explicit evidence (block closed, session destroyed, a successful
    /// read without the record or with another emission), never because a snapshot lacks them:
    /// a restarting server may list only some sessions. The cap bounds what is left behind.
    private mutating func removeDismissals(where shouldRemove: (RexRecordKey) -> Bool) {
        for key in dismissed.keys where shouldRemove(key) {
            removeDismissal(key)
        }
    }

    private mutating func completeSnapshot(into output: inout RexReducerOutput) {
        isSnapshotDone = true

        // 1. Prune what this generation's snapshot no longer contains, keeping the history of
        //    blocks it could not read (a failed status read, or a session whose block list failed).
        let readBlocks = Set(blockRecords.keys)
        let unreadBlocks = unreadBlocks, unreadSessions = unreadSessions
        let liveSessions = Set(sessions.keys)
        dropLastKnown {
            let block = BlockKey(sessionID: $0.sessionID, blockID: $0.blockID)
            if readBlocks.contains(block) { return false }
            let unread = unreadBlocks.contains(block) || unreadSessions.contains($0.sessionID)
            return !(unread && liveSessions.contains($0.sessionID))
        }

        // Silent baselines: the first successful snapshot settles everything; later ones settle
        // sessions the store has not been told about (created during an outage).
        if hasCompletedFirstSnapshot {
            let known = sessionsKnownToStore
            settleImmediately { !known.contains($0.sessionID) }
        } else {
            settleImmediately { _ in true }
            hasCompletedFirstSnapshot = true
            lateBaseline = LateBaseline(
                cutoff: wallClock() - Self.lateBaselineTolerance,
                seeds: seedsDismissalsAtFirstSnapshot,
                blocks: unreadBlocks,
                sessions: unreadSessions.intersection(liveSessions)
            )
            if seedsDismissalsAtFirstSnapshot { seedDismissals() }
        }

        // 2–4. Discovery, then `.connected` per session, then `.removed` for vanished sessions.
        let descriptors = sessions.keys.map(descriptor).sorted(by: RexRows.compareSessions)
        output.events.append(.discovery(descriptors))
        for descriptor in descriptors {
            let snapshot = snapshot(forSession: descriptor.key.rawID)
            lastEmitted[descriptor.key.rawID] = snapshot
            output.events.append(.connected(descriptor, snapshot))
        }
        let vanished = sessionsKnownToStore.subtracting(sessions.keys).sorted()
        sessionsKnownToStore = Set(sessions.keys)
        for sessionID in vanished {
            output.events.append(.removed(key(sessionID)))
        }
    }

    /// Upgrade or first run: dismiss every settled, unseen terminal record that has an
    /// `updated_at`, and mark the (possibly empty) result for saving so later launches load it.
    private mutating func seedDismissals() {
        seedsDismissalsAtFirstSnapshot = false
        for (key, known) in lastKnown
        where Self.isTerminal(known.state) && known.updatedAt != nil
            && settled[key] == known.epoch && seenMarks[key] != known.epoch {
            dismiss(key, known)
        }
        dismissalsRevision += 1
    }

    private func emitDescriptorChange(_ sessionID: String, oldName: String, into output: inout RexReducerOutput) {
        guard isSnapshotDone, sessionsKnownToStore.contains(sessionID) else { return }
        let new = descriptor(sessionID)
        if new.displayName != oldName { output.events.append(.descriptorChanged(new)) }
    }

    private mutating func emitChangedSnapshots(for sessionIDs: Set<String>, into output: inout RexReducerOutput) {
        guard isSnapshotDone else { return }
        for sessionID in sessionIDs.sorted() where sessionsKnownToStore.contains(sessionID) && sessions[sessionID] != nil {
            let snapshot = snapshot(forSession: sessionID)
            guard lastEmitted[sessionID] != snapshot else { continue }
            lastEmitted[sessionID] = snapshot
            output.events.append(.snapshot(key(sessionID), snapshot))
        }
    }

    // MARK: Helpers

    private func displayName(_ sessionID: String) -> String {
        RexRows.sessionDisplayName(sessions[sessionID]?.label)
    }

    private func key(_ sessionID: String) -> AgentSessionKey {
        AgentSessionKey(backend: .rex, rawID: sessionID)
    }

    private func recordKey(_ sessionID: String, _ blockID: String, _ recordID: String) -> RexRecordKey {
        RexRecordKey(sessionID: sessionID, blockID: blockID, recordID: recordID)
    }
}
