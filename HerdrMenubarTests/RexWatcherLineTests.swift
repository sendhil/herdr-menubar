import XCTest
@testable import HerdrMenubar

final class RexWatcherLineTests: XCTestCase {
    private func decode(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> RexWatcherLine {
        try RexWatcherLine.decode(Data(json.utf8))
    }

    // MARK: Timestamps

    func testTimestampWithMicrosecondsAndNegativeOffset() {
        // 2026-11-08T01:18:12.541659Z
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-07T17:18:12.541659-08:00"), 1_794_100_692_541_659)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-08T01:18:12.541659Z"), 1_794_100_692_541_659)
    }

    func testTimestampWithTrimmedOrMissingFractionalDigits() {
        let base: Int64 = 1_794_100_692_000_000
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-08T01:18:12Z"), base)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-08T01:18:12.5Z"), base + 500_000)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-08T01:18:12.54Z"), base + 540_000)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-08T01:18:12.77673Z"), base + 776_730)
        // Digits beyond microseconds are truncated, never rounded up.
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-11-08T01:18:12.123456789Z"), base + 123_456)
    }

    func testTimestampOffsetsAreApplied() {
        let utc = RexTimestamp.microseconds(from: "2026-01-01T00:00:00Z")
        XCTAssertEqual(utc, 1_767_225_600_000_000)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-01-01T05:30:00+05:30"), utc)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2025-12-31T16:00:00-08:00"), utc)
        XCTAssertEqual(RexTimestamp.microseconds(from: "2026-01-01t00:00:00z"), utc)
        XCTAssertEqual(RexTimestamp.microseconds(from: "1970-01-01T00:00:00Z"), 0)
    }

    func testTimestampOrderingIsNotTextual() throws {
        // Text order would put ".5" after ".49999"; numeric order agrees, but variable width breaks
        // comparisons such as "12Z" vs "12.1Z" and differing offsets.
        let a = try XCTUnwrap(RexTimestamp.microseconds(from: "2026-11-07T17:18:12-08:00"))
        let b = try XCTUnwrap(RexTimestamp.microseconds(from: "2026-11-08T01:18:12.000001Z"))
        XCTAssertLessThan(a, b)
    }

    func testMalformedTimestampsAreNil() {
        for text in ["", "2026-11-07", "2026-11-07T17:18:12", "2026-13-07T17:18:12Z", "2026-11-07T25:18:12Z",
                     "2026-11-07T17:18:12.Z", "2026-11-07T17:18:12+0800", "x026-11-07T17:18:12Z",
                     "2026-11-07T17:18:12Zjunk", "2026-02-30T00:00:00Z"] {
            XCTAssertNil(RexTimestamp.microseconds(from: text), text)
        }
    }

    // MARK: Line kinds

    func testDecodesSessionAndView() throws {
        XCTAssertEqual(try decode(#"{"label":"Default","s":"session:1","t":"session"}"#),
                       .session(id: "session:1", label: "Default"))
        XCTAssertEqual(
            try decode(#"{"blocks":[{"b":"block:1","block_label":"shell","creator":"com.superlogical.terminal","window_id":"window:01a1b7de-bd46-78ae-9fcb-30b6930b211f","window_label":"Window 930b211f"}],"s":"session:1","session_label":"Default","t":"view"}"#),
            .view(RexSessionView(sessionID: "session:1", sessionLabel: "Default", blocks: [
                RexViewBlock(blockID: "block:1", creator: "com.superlogical.terminal",
                             windowID: "window:01a1b7de-bd46-78ae-9fcb-30b6930b211f",
                             windowLabel: "Window 930b211f", blockLabel: "shell"),
            ]))
        )
    }

    func testEmptyObjectArraysDecodeAsEmpty() throws {
        XCTAssertEqual(try decode(#"{"blocks":{},"s":"session:1","t":"view"}"#),
                       .view(RexSessionView(sessionID: "session:1", sessionLabel: nil, blocks: [])))
        XCTAssertEqual(try decode(#"{"b":"block:1","records":{},"s":"session:1","t":"block"}"#),
                       .block(RexBlockRead(sessionID: "session:1", blockID: "block:1", records: [], gone: false, via: nil)))
        // Missing arrays (rex.json.encode drops nil fields) are empty too.
        XCTAssertEqual(try decode(#"{"b":"block:1","s":"session:1","t":"block"}"#),
                       .block(RexBlockRead(sessionID: "session:1", blockID: "block:1", records: [], gone: false, via: nil)))
    }

    func testNonEmptyObjectWhereAnArrayIsExpectedIsAnError() {
        XCTAssertThrowsError(try decode(#"{"b":"block:1","records":{"x":1},"s":"session:1","t":"block"}"#))
    }

    func testDecodesBlockRecordsWithParsedTimestampsAndOptionalFields() throws {
        let line = try decode(#"{"b":"block:1","records":[{"app":"claude-code","at":"2026-11-07T22:08:36.183549-08:00","id":"","state":"working"},{"app":"pi","at":"2026-11-08T06:09:34.39Z","id":"tz5","kind":"permission","msg":"Allow rm < x?","state":"blocked","title":"Step 2"}],"s":"session:1","t":"block"}"#)
        guard case .block(let read) = line else { return XCTFail("\(line)") }
        XCTAssertEqual(read.records, [
            RexRecord(id: "", state: "working", kind: nil, updatedAt: 1_794_118_116_183_549, app: "claude-code", title: nil, msg: nil),
            RexRecord(id: "tz5", state: "blocked", kind: "permission", updatedAt: 1_794_118_174_390_000, app: "pi", title: "Step 2", msg: "Allow rm < x?"),
        ])
        XCTAssertEqual(read.records.map(\.programState), [.working, .blocked])
    }

    func testRecordWithoutIdIsRootAndUnknownStateIsKept() throws {
        let line = try decode(#"{"b":"b","records":[{"state":"thinking","at":"bogus"}],"s":"s","t":"block"}"#)
        guard case .block(let read) = line else { return XCTFail("\(line)") }
        XCTAssertEqual(read.records, [RexRecord(id: "", state: "thinking", kind: nil, updatedAt: nil, app: nil, title: nil, msg: nil)])
        XCTAssertNil(read.records[0].programState)
    }

    func testDecodesViaForChangeRemovalAndGone() throws {
        XCTAssertEqual(
            try decode(#"{"b":"b","records":{},"s":"s","t":"block","via":{"at":"2026-01-01T00:00:00Z","id":"","state":"done"}}"#),
            .block(RexBlockRead(sessionID: "s", blockID: "b", records: [], gone: false,
                                via: RexVia(id: "", state: "done", updatedAt: 1_767_225_600_000_000, removedIDs: [])))
        )
        XCTAssertEqual(
            try decode(#"{"b":"b","gone":true,"records":{},"s":"s","t":"block","via":{"removed":["","c1"]}}"#),
            .block(RexBlockRead(sessionID: "s", blockID: "b", records: [], gone: true,
                                via: RexVia(id: "", state: nil, updatedAt: nil, removedIDs: ["", "c1"])))
        )
        // A via with no id names the root record.
        XCTAssertEqual(
            try decode(#"{"b":"b","records":{},"s":"s","t":"block","via":{"state":"working"}}"#),
            .block(RexBlockRead(sessionID: "s", blockID: "b", records: [], gone: false,
                                via: RexVia(id: "", state: "working", updatedAt: nil, removedIDs: [])))
        )
    }

    func testDecodesLifecycleAndErrorLines() throws {
        XCTAssertEqual(try decode(#"{"b":"b","s":"s","t":"block_closed"}"#), .blockClosed(sessionID: "s", blockID: "b"))
        XCTAssertEqual(try decode(#"{"s":"s","t":"session_destroyed"}"#), .sessionDestroyed(sessionID: "s"))
        XCTAssertEqual(try decode(#"{"label":"L","s":"s","t":"session_created"}"#), .sessionCreated(sessionID: "s", label: "L"))
        XCTAssertEqual(try decode(#"{"s":"s","t":"session_created"}"#), .sessionCreated(sessionID: "s", label: nil))
        XCTAssertEqual(try decode(#"{"t":"snapshot_done"}"#), .snapshotDone)
        XCTAssertEqual(try decode(#"{"t":"heartbeat"}"#), .heartbeat)
        XCTAssertEqual(try decode(#"{"b":"b","err":"boom","s":"s","t":"status_error"}"#), .statusError(sessionID: "s", blockID: "b", message: "boom"))
        XCTAssertEqual(try decode(#"{"err":"boom","s":"s","t":"view_error"}"#), .viewError(sessionID: "s", message: "boom"))
        XCTAssertEqual(try decode(#"{"err":"session.list: x","t":"snapshot_error"}"#), .snapshotError(message: "session.list: x"))
        XCTAssertEqual(try decode(#"{"err":"NaN","t":"encode_error"}"#), .encodeError(message: "NaN"))
        XCTAssertEqual(try decode(#"{"t":"something_new","x":1}"#), .unknown(type: "something_new"))
    }

    func testFatalLinesAreClassified() throws {
        XCTAssertTrue(RexWatcherLine.snapshotError(message: "x").isAlwaysFatal)
        XCTAssertTrue(RexWatcherLine.encodeError(message: "x").isAlwaysFatal)
        XCTAssertFalse(RexWatcherLine.statusError(sessionID: "s", blockID: "b", message: "x").isAlwaysFatal)
        XCTAssertFalse(RexWatcherLine.heartbeat.isAlwaysFatal)
    }

    func testMalformedLinesThrow() {
        for json in ["not json", "[]", #"{"s":"s"}"#, #"{"t":"session"}"#, #"{"t":"block","s":"s"}"#,
                     #"{"t":"block_closed","s":"s"}"#, #"{"t":"status_error","s":"s","b":"b"}"#, #"{"t":7}"#] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    // MARK: Recorded fixture

    func testRecordedLiveSnapshotFixtureDecodesCompletely() throws {
        let lines = try RexFixtures.lines(named: "snapshot-live")
        XCTAssertFalse(lines.isEmpty)
        let decoded = try lines.map { try RexWatcherLine.decode($0) }
        XCTAssertFalse(decoded.contains { if case .unknown = $0 { true } else { false } })
        XCTAssertTrue(decoded.contains(.snapshotDone))
        let sessions = decoded.compactMap { if case .session(let id, _) = $0 { id } else { nil } }
        let views = decoded.compactMap { if case .view(let view) = $0 { view } else { nil } }
        XCTAssertEqual(Set(views.map(\.sessionID)), Set(sessions))
        let records: [RexRecord] = decoded.flatMap { line -> [RexRecord] in if case .block(let read) = line { read.records } else { [] } }
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { $0.updatedAt != nil })
        // Every session's lines precede snapshot_done.
        let doneIndex = try XCTUnwrap(decoded.firstIndex(of: .snapshotDone))
        XCTAssertTrue(decoded[..<doneIndex].allSatisfy { if case .heartbeat = $0 { false } else { true } })
    }
}

enum RexFixtures {
    static func url(named name: String) throws -> URL {
        let bundle = Bundle(for: RexFixtureBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Rex") else {
            throw NSError(domain: "RexFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return url
    }

    static func lines(named name: String) throws -> [Data] {
        var framer = JSONLineFramer()
        let lines = framer.append(try Data(contentsOf: url(named: name)))
        try framer.finish()
        return lines
    }
}

private final class RexFixtureBundleToken {}
