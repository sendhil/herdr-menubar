import Foundation

// Decoding for the JSON lines printed by the bundled `RexWatcher.lua`.
// Field names follow the script: `t` is the line kind, `s` a session id, `b` a block id.

/// Program Status Protocol states the menu understands. Anything else is carried as raw text in
/// `RexRecord.state` (`programState == nil`) and ignored by ranking, as is `idle`.
enum RexProgramState: String, Sendable, CaseIterable {
    case blocked, working, error, done, idle
}

/// One `program_status` record as re-read by the watcher.
struct RexRecord: Equatable, Sendable {
    /// `""` for the block's root record.
    let id: String
    let state: String
    let kind: String?
    /// `updated_at` in microseconds since the Unix epoch, offset applied; nil if absent or unparseable.
    let updatedAt: Int64?
    /// `effective_app`, falling back to `app` (chosen in Lua).
    let app: String?
    let title: String?
    /// Already clipped to 300 bytes on a UTF-8 boundary by the script. Not yet sanitized.
    let msg: String?

    var programState: RexProgramState? { RexProgramState(rawValue: state) }
}

/// What the event that triggered a re-read said. Absent for snapshot reads.
struct RexVia: Equatable, Sendable {
    /// Record id of a `program_status_changed` event (`""` = root, also when the field is missing).
    let id: String
    /// State from the event; nil for removals.
    let state: String?
    /// Event `updated_at` in microseconds; nil if absent or unparseable.
    let updatedAt: Int64?
    /// Ids from a `program_status_removed` event; empty for changes.
    let removedIDs: [String]
}

/// A `block` line: the authoritative current records of one block.
struct RexBlockRead: Equatable, Sendable {
    let sessionID: String
    let blockID: String
    let records: [RexRecord]
    /// The block or session no longer exists (404). `records` is then empty; treat as an empty read.
    let gone: Bool
    let via: RexVia?
}

struct RexViewBlock: Equatable, Sendable {
    let blockID: String
    let creator: String?
    let windowID: String?
    let windowLabel: String?
    let blockLabel: String?
}

/// A `view` line: every placed block of a session, in window → layer → block order.
struct RexSessionView: Equatable, Sendable {
    let sessionID: String
    let sessionLabel: String?
    let blocks: [RexViewBlock]
}

enum RexWatcherLineError: Error, Equatable, Sendable {
    case invalidJSON(String)
}

/// Every line kind `RexWatcher.lua` emits.
enum RexWatcherLine: Equatable, Sendable {
    /// Snapshot only: a listed session and its label.
    case session(id: String, label: String?)
    case view(RexSessionView)
    case block(RexBlockRead)
    case blockClosed(sessionID: String, blockID: String)
    case sessionDestroyed(sessionID: String)
    case sessionCreated(sessionID: String, label: String?)
    case snapshotDone
    case heartbeat
    /// `program_status` failed with something other than not-found.
    case statusError(sessionID: String, blockID: String, message: String)
    /// `session.view` failed with something other than not-found.
    case viewError(sessionID: String, message: String)
    case snapshotError(message: String)
    case encodeError(message: String)
    /// A well-formed line with a `t` this build does not know. Ignore (log) it.
    case unknown(type: String)

    /// Lines that are a watcher failure regardless of snapshot progress. (`status_error` and
    /// `view_error` are failures only before `snapshot_done`; oversized lines are framing errors.)
    var isAlwaysFatal: Bool {
        switch self {
        case .snapshotError, .encodeError: true
        default: false
        }
    }

    /// Throws `RexWatcherLineError.invalidJSON` for invalid JSON or a known kind missing a field.
    static func decode(_ data: Data) throws -> RexWatcherLine {
        do {
            return try JSONDecoder().decode(RexWatcherLine.self, from: data)
        } catch {
            throw RexWatcherLineError.invalidJSON(String(describing: error))
        }
    }
}

extension RexWatcherLine: Decodable {
    private enum Key: String, CodingKey {
        case t, s, b, label, err, records, gone, via, blocks
        case sessionLabel = "session_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .t)
        switch type {
        case "session":
            self = .session(id: try c.decode(String.self, forKey: .s),
                            label: try c.decodeIfPresent(String.self, forKey: .label))
        case "view":
            self = .view(RexSessionView(
                sessionID: try c.decode(String.self, forKey: .s),
                sessionLabel: try c.decodeIfPresent(String.self, forKey: .sessionLabel),
                blocks: try c.decodeLenientArray(WireViewBlock.self, forKey: .blocks).map(\.value)
            ))
        case "block":
            self = .block(RexBlockRead(
                sessionID: try c.decode(String.self, forKey: .s),
                blockID: try c.decode(String.self, forKey: .b),
                records: try c.decodeLenientArray(WireRecord.self, forKey: .records).map(\.value),
                gone: try c.decodeIfPresent(Bool.self, forKey: .gone) ?? false,
                via: try c.decodeIfPresent(WireVia.self, forKey: .via)?.value
            ))
        case "block_closed":
            self = .blockClosed(sessionID: try c.decode(String.self, forKey: .s),
                                blockID: try c.decode(String.self, forKey: .b))
        case "session_destroyed":
            self = .sessionDestroyed(sessionID: try c.decode(String.self, forKey: .s))
        case "session_created":
            self = .sessionCreated(sessionID: try c.decode(String.self, forKey: .s),
                                   label: try c.decodeIfPresent(String.self, forKey: .label))
        case "snapshot_done":
            self = .snapshotDone
        case "heartbeat":
            self = .heartbeat
        case "status_error":
            self = .statusError(sessionID: try c.decode(String.self, forKey: .s),
                                blockID: try c.decode(String.self, forKey: .b),
                                message: try c.decode(String.self, forKey: .err))
        case "view_error":
            self = .viewError(sessionID: try c.decode(String.self, forKey: .s),
                              message: try c.decode(String.self, forKey: .err))
        case "snapshot_error":
            self = .snapshotError(message: try c.decodeIfPresent(String.self, forKey: .err) ?? "")
        case "encode_error":
            self = .encodeError(message: try c.decodeIfPresent(String.self, forKey: .err) ?? "")
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: Wire shapes

private struct WireRecord: Decodable {
    let value: RexRecord

    private enum Key: String, CodingKey { case id, state, kind, at, app, title, msg }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        value = RexRecord(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            state: try c.decode(String.self, forKey: .state),
            kind: try c.decodeIfPresent(String.self, forKey: .kind),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .at).flatMap(RexTimestamp.microseconds(from:)),
            app: try c.decodeIfPresent(String.self, forKey: .app),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            msg: try c.decodeIfPresent(String.self, forKey: .msg)
        )
    }
}

private struct WireVia: Decodable {
    let value: RexVia

    private enum Key: String, CodingKey { case id, state, at, removed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        value = RexVia(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            state: try c.decodeIfPresent(String.self, forKey: .state),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .at).flatMap(RexTimestamp.microseconds(from:)),
            removedIDs: try c.decodeLenientArray(String.self, forKey: .removed)
        )
    }
}

private struct WireViewBlock: Decodable {
    let value: RexViewBlock

    private enum Key: String, CodingKey {
        case b, creator
        case windowID = "window_id"
        case windowLabel = "window_label"
        case blockLabel = "block_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        value = RexViewBlock(
            blockID: try c.decode(String.self, forKey: .b),
            creator: try c.decodeIfPresent(String.self, forKey: .creator),
            windowID: try c.decodeIfPresent(String.self, forKey: .windowID),
            windowLabel: try c.decodeIfPresent(String.self, forKey: .windowLabel),
            blockLabel: try c.decodeIfPresent(String.self, forKey: .blockLabel)
        )
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct EmptyObject: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        guard c.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "expected an array or an empty object"))
        }
    }
}

extension KeyedDecodingContainer {
    /// `rex.json.encode` writes an empty Lua table as `{}` and drops nil fields (F6), so an array
    /// field may arrive as `[...]`, `{}`, `null`, or not at all. The last three mean `[]`.
    /// A non-empty object (or any other type) is an error.
    func decodeLenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        if let array = try? decode([T].self, forKey: key) { return array }
        _ = try decode(EmptyObject.self, forKey: key)
        return []
    }
}

// MARK: Timestamps

/// RFC 3339 timestamps as Rex prints them (F8): local offset or `Z`, 0–9 fractional digits with
/// trailing zeros trimmed. Never compare them as text.
enum RexTimestamp {
    /// Microseconds since the Unix epoch with the offset applied. Digits beyond microseconds are
    /// truncated. Returns nil for anything that is not a complete, valid RFC 3339 date-time.
    static func microseconds(from text: String) -> Int64? {
        let b = Array(text.utf8)
        var i = 0

        func digits(_ count: Int) -> Int? {
            guard i + count <= b.count else { return nil }
            var value = 0
            for _ in 0..<count {
                let d = b[i]
                guard d >= 0x30, d <= 0x39 else { return nil }
                value = value * 10 + Int(d - 0x30)
                i += 1
            }
            return value
        }
        func expect(_ byte: UInt8) -> Bool {
            guard i < b.count, b[i] == byte else { return false }
            i += 1
            return true
        }

        guard let year = digits(4), expect(0x2D), let month = digits(2), expect(0x2D),
              let day = digits(2) else { return nil }
        guard i < b.count, b[i] == 0x54 || b[i] == 0x74 || b[i] == 0x20 else { return nil }   // T, t, space
        i += 1
        guard let hour = digits(2), expect(0x3A), let minute = digits(2), expect(0x3A),
              let second = digits(2) else { return nil }
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 60 else { return nil }

        var micros: Int64 = 0
        if i < b.count, b[i] == 0x2E {   // .
            i += 1
            var count = 0
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if count < 6 { micros = micros * 10 + Int64(b[i] - 0x30) }
                count += 1
                i += 1
            }
            guard count > 0 else { return nil }
            if count < 6 {
                for _ in count..<6 { micros *= 10 }
            }
        }

        var offsetSeconds = 0
        guard i < b.count else { return nil }
        if b[i] == 0x5A || b[i] == 0x7A {   // Z, z
            i += 1
        } else if b[i] == 0x2B || b[i] == 0x2D {   // +, -
            let sign = b[i] == 0x2D ? -1 : 1
            i += 1
            guard let oh = digits(2), expect(0x3A), let om = digits(2), oh <= 23, om <= 59 else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == b.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return seconds * 1_000_000 + micros
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
