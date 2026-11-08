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
/// `.backendUnavailable(reason)`, and restarts with backoff.
enum RexWatcherFailure: Equatable, Sendable {
    case snapshotError(String)
    case encodeError(String)
    /// `status_error` before `snapshot_done`.
    case statusError(sessionID: String, blockID: String, message: String)
    /// `view_error` before `snapshot_done`.
    case viewError(sessionID: String, message: String)

    var reason: String {
        switch self {
        case .snapshotError(let message): "Rex watcher snapshot failed: \(message)"
        case .encodeError(let message): "Rex watcher could not encode a line: \(message)"
        case .statusError(_, _, let message): "Rex watcher could not read program status: \(message)"
        case .viewError(_, let message): "Rex watcher could not read a session view: \(message)"
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
    /// Seen marks: the epoch of each record the user has seen. A `done`/`error` record is hidden
    /// iff its mark equals its current epoch. Pruned when the record gets a new epoch or is dropped.
    private var seenMarks: [RexRecordKey: Int] = [:]
    /// Settled epochs (flap protection). A record is in `attention` iff its current epoch is here.
    private var settled: [RexRecordKey: Int] = [:]
    /// Set at the first successful `snapshot_done` since start, whose records all settle at once.
    private var hasCompletedFirstSnapshot = false
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
    }

    /// `stop()`: forget everything except the epoch counter's value. The next generation's first
    /// successful snapshot is a fresh "first".
    mutating func reset() {
        let counter = epochCounter
        self = RexReducer()
        epochCounter = counter
    }

    // MARK: Lines

    /// Applies one decoded watcher line. Lines of any other generation are ignored.
    mutating func apply(_ line: RexWatcherLine, generation: Int, now: ContinuousClock.Instant) -> RexReducerOutput {
        var output = RexReducerOutput()
        guard generation == self.generation else { return output }

        var affected = settleDue(now: now)
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
            affected.insert(sessionID)

        case .sessionDestroyed(let sessionID):
            sessions[sessionID] = nil
            blockRecords = blockRecords.filter { $0.key.sessionID != sessionID }
            dropLastKnown { $0.sessionID == sessionID }
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
            if isSnapshotDone {
                output.logMessages.append("Rex status read failed for \(blockID) in \(sessionID): \(message)")
            } else {
                output.failure = .statusError(sessionID: sessionID, blockID: blockID, message: message)
            }

        case .viewError(let sessionID, let message):
            if isSnapshotDone {
                output.logMessages.append("Rex view read failed for \(sessionID): \(message)")
            } else {
                output.failure = .viewError(sessionID: sessionID, message: message)
            }

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

    /// Marks every `(record key, epoch)` in the token whose epoch is still current. Returns
    /// `.snapshot` events for sessions whose rows changed (none before `snapshot_done`).
    mutating func markSeen(_ token: SeenToken) -> [BackendEvent] {
        var affected: Set<String> = []
        for (key, known) in lastKnown where Self.isTerminal(known.state) && seenMarks[key] != known.epoch {
            guard token.marks.contains(Self.mark(key, epoch: known.epoch)) else { continue }
            seenMarks[key] = known.epoch
            affected.insert(key.sessionID)
        }
        var output = RexReducerOutput()
        emitChangedSnapshots(for: affected, into: &output)
        return output.events
    }

    /// Clear Finished: marks every unseen `done` record of every placed block.
    mutating func clearFinished() -> [BackendEvent] {
        var affected: Set<String> = []
        for (sessionID, session) in sessions {
            for block in session.view?.blocks ?? [] {
                for record in blockRecords[BlockKey(sessionID: sessionID, blockID: block.blockID)] ?? []
                where record.programState == .done {
                    let key = recordKey(sessionID, block.blockID, record.id)
                    guard let epoch = lastKnown[key]?.epoch, seenMarks[key] != epoch else { continue }
                    seenMarks[key] = epoch
                    affected.insert(sessionID)
                }
            }
        }
        var output = RexReducerOutput()
        emitChangedSnapshots(for: affected, into: &output)
        return output.events
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
                guard let state = candidate.record.programState.flatMap(RexRows.attentionState),
                      settled[recordKey(sessionID, block.blockID, candidate.record.id)] == candidate.epoch
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
        return BackendSnapshot(rows: rows, attention: orderedAttention)
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
            if let known = lastKnown[key], viaAt > (known.updatedAt ?? .min), viaState != known.state {
                setLastKnown(key, state: viaState, updatedAt: viaAt, newEpoch: true, now: now)
            }
        }

        // 2. Re-read: replace the block's records; a new or changed state gets a new epoch.
        var current: [RexRecord] = []
        var seenIDs: Set<String> = []
        for record in records where seenIDs.insert(record.id).inserted {
            current.append(record)
        }
        for record in current {
            let key = recordKey(read.sessionID, read.blockID, record.id)
            let changed = lastKnown[key].map { $0.state != record.state } ?? true
            setLastKnown(key, state: record.state, updatedAt: record.updatedAt, newEpoch: changed, now: now)
        }
        blockRecords[BlockKey(sessionID: read.sessionID, blockID: read.blockID)] = current

        // 3. Drop records absent from the read.
        dropLastKnown { $0.sessionID == read.sessionID && $0.blockID == read.blockID && !seenIDs.contains($0.recordID) }
    }

    private mutating func setLastKnown(_ key: RexRecordKey, state: String, updatedAt: Int64?, newEpoch: Bool,
                                       now: ContinuousClock.Instant) {
        if newEpoch || lastKnown[key] == nil {
            epochCounter += 1
            lastKnown[key] = LastKnown(state: state, updatedAt: updatedAt, epoch: epochCounter, epochStart: now)
            seenMarks[key] = nil
            settled[key] = nil
        } else {
            lastKnown[key]?.state = state
            lastKnown[key]?.updatedAt = updatedAt
        }
    }

    private mutating func dropLastKnown(where shouldDrop: (RexRecordKey) -> Bool) {
        for key in lastKnown.keys where shouldDrop(key) {
            lastKnown[key] = nil
            seenMarks[key] = nil
            settled[key] = nil
        }
    }

    private mutating func completeSnapshot(into output: inout RexReducerOutput) {
        isSnapshotDone = true

        // 1. Prune what this generation's snapshot no longer contains.
        let readBlocks = Set(blockRecords.keys)
        dropLastKnown { !readBlocks.contains(BlockKey(sessionID: $0.sessionID, blockID: $0.blockID)) }

        // Silent baselines: the first successful snapshot settles everything; later ones settle
        // sessions the store has not been told about (created during an outage).
        if hasCompletedFirstSnapshot {
            let known = sessionsKnownToStore
            settleImmediately { !known.contains($0.sessionID) }
        } else {
            settleImmediately { _ in true }
            hasCompletedFirstSnapshot = true
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
