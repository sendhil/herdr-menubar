import Foundation
import XCTest
@testable import HerdrMenubar

/// Hand-written watcher lines in the exact shape `RexWatcher.lua` prints, decoded through
/// `RexWatcherLine.decode` so the tests exercise the real wire format.
enum RexLines {
    static let terminal = "com.superlogical.terminal"

    struct Rec {
        var id = ""
        var state: String
        var at: Int = 0
        var app: String? = nil
        var title: String? = nil
        var msg: String? = nil
        var kind: String? = nil
    }

    struct ViewBlock {
        var b: String
        var windowID = "window:01a1b7c1-0f65-7157-a243-360e2bd966f9"
        var windowLabel = "Window 2bd966f9"
        var blockLabel = "shell"
    }

    /// RFC 3339 with a local offset and trimmed fraction, `n` seconds after a fixed base.
    static func ts(_ n: Int) -> String {
        String(format: "2026-11-07T18:%02d:%02d.5-08:00", n / 60, n % 60)
    }

    static func micros(_ n: Int) -> Int64 {
        RexTimestamp.microseconds(from: ts(n))!
    }

    static func decode(_ object: [String: Any]) -> RexWatcherLine {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try! RexWatcherLine.decode(data)
    }

    static func session(_ s: String, label: String? = nil) -> RexWatcherLine {
        var o: [String: Any] = ["t": "session", "s": s]
        o["label"] = label
        return decode(o)
    }

    static func view(_ s: String, label: String? = nil, _ blocks: [ViewBlock]) -> RexWatcherLine {
        var o: [String: Any] = ["t": "view", "s": s]
        o["session_label"] = label
        o["blocks"] = blocks.isEmpty ? [String: Any]() as Any : blocks.map { vb -> [String: Any] in
            ["b": vb.b, "creator": terminal, "window_id": vb.windowID, "window_label": vb.windowLabel,
             "block_label": vb.blockLabel]
        }
        return decode(o)
    }

    static func block(_ s: String, _ b: String, _ records: [Rec], gone: Bool = false,
                      via: [String: Any]? = nil) -> RexWatcherLine {
        var o: [String: Any] = ["t": "block", "s": s, "b": b]
        o["records"] = records.isEmpty ? [String: Any]() as Any : records.map { r -> [String: Any] in
            var d: [String: Any] = ["id": r.id, "state": r.state, "at": ts(r.at)]
            d["app"] = r.app; d["title"] = r.title; d["msg"] = r.msg; d["kind"] = r.kind
            return d
        }
        if gone { o["gone"] = true }
        o["via"] = via
        return decode(o)
    }

    static func changed(id: String = "", _ state: String, at: Int) -> [String: Any] {
        ["id": id, "state": state, "at": ts(at)]
    }

    static func removed(_ ids: [String]) -> [String: Any] {
        ["removed": ids]
    }

    static func line(_ object: [String: Any]) -> RexWatcherLine { decode(object) }
}

/// Drives a reducer with a manual clock.
struct RexReducerHarness {
    var reducer = RexReducer()
    var generation = 1
    let start = ContinuousClock.now
    var elapsed: Duration = .zero
    var now: ContinuousClock.Instant { start + elapsed }

    init(generation: Int = 1) {
        self.generation = generation
        reducer.beginGeneration(generation)
    }

    @discardableResult
    mutating func apply(_ line: RexWatcherLine) -> RexReducerOutput {
        reducer.apply(line, generation: generation, now: now)
    }

    @discardableResult
    mutating func apply(_ lines: [RexWatcherLine]) -> [BackendEvent] {
        lines.flatMap { apply($0).events }
    }

    mutating func restart() {
        generation += 1
        reducer.beginGeneration(generation)
    }
}

extension BackendEvent {
    var snapshotPayload: (AgentSessionKey, BackendSnapshot)? {
        switch self {
        case .connected(let d, let s): (d.key, s)
        case .snapshot(let k, let s): (k, s)
        default: nil
        }
    }
}

extension Array where Element == BackendEvent {
    /// The last snapshot (from `.connected` or `.snapshot`) emitted for a session.
    func lastSnapshot(_ s: String) -> BackendSnapshot? {
        compactMap(\.snapshotPayload).last { $0.0.rawID == s }?.1
    }
}

func rexKey(_ s: String) -> AgentSessionKey { AgentSessionKey(backend: .rex, rawID: s) }
func rexDescriptor(_ s: String, _ name: String) -> AgentSessionDescriptor {
    AgentSessionDescriptor(key: rexKey(s), displayName: name)
}
