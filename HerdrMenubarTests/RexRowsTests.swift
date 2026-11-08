import XCTest
@testable import HerdrMenubar

final class RexRowsTests: XCTestCase {
    private let session = AgentSessionKey(backend: .rex, rawID: "session:1")

    private func record(_ state: String, id: String = "", app: String? = nil, title: String? = nil, msg: String? = nil) -> RexRecord {
        RexRecord(id: id, state: state, kind: nil, updatedAt: 1, app: app, title: title, msg: msg)
    }

    private func block(window: String? = "Window 2bd966f9",
                       windowID: String? = "window:01a1b7c1-0f65-7157-a243-360e2bd966f9",
                       label: String? = "shell") -> RexViewBlock {
        RexViewBlock(blockID: "block:1", creator: "com.superlogical.terminal", windowID: windowID,
                     windowLabel: window, blockLabel: label)
    }

    // MARK: Sanitization

    func testSanitizeRemovesFormatAndControlCharacters() {
        XCTAssertEqual(RexText.sanitize("a\u{202E}b\u{200B}c\u{0007}d\u{FEFF}"), "abcd")
        XCTAssertEqual(RexText.sanitize("\u{1B}[31mred"), "[31mred")
    }

    func testSanitizeCollapsesWhitespaceIncludingNewlinesAndTrims() {
        XCTAssertEqual(RexText.sanitize("  Allow\n\n rm\t-rf\u{2028}build?  "), "Allow rm -rf build?")
        XCTAssertEqual(RexText.sanitize("a \u{200E} b"), "a b")
    }

    func testSanitizeTruncatesTo200Characters() {
        let long = String(repeating: "é", count: 250)
        XCTAssertEqual(RexText.sanitize(long).count, 200)
        XCTAssertEqual(RexText.sanitize(String(repeating: "x", count: 200)).count, 200)
    }

    func testSanitizedNonEmptyIsNilForBlankText() {
        XCTAssertNil(RexText.sanitizedNonEmpty(nil))
        XCTAssertNil(RexText.sanitizedNonEmpty(" \u{200F}\n"))
        XCTAssertEqual(RexText.sanitizedNonEmpty(" pi "), "pi")
    }

    // MARK: Labels

    func testDefaultWindowLabelDetectedByWindowID() {
        let id = "window:01a1b7c1-0f65-7157-a243-360e2bd966f9"
        XCTAssertTrue(RexRows.isDefaultWindowLabel("Window 2bd966f9", windowID: id))
        XCTAssertFalse(RexRows.isDefaultWindowLabel("Window 930b211f", windowID: id))
        XCTAssertFalse(RexRows.isDefaultWindowLabel("Window 2bd966f9", windowID: nil))
        XCTAssertFalse(RexRows.isDefaultWindowLabel("slow startup", windowID: id))
    }

    func testPrimaryLabelPrefersNamedWindowThenNamedBlockThenSession() {
        XCTAssertEqual(RexRows.primaryLabel(block: block(window: "slow startup", label: "floatA"), sessionLabel: "S"), "slow startup")
        XCTAssertEqual(RexRows.primaryLabel(block: block(label: "floatA"), sessionLabel: "S"), "floatA")
        XCTAssertEqual(RexRows.primaryLabel(block: block(), sessionLabel: "fix-playback"), "fix-playback")
        XCTAssertEqual(RexRows.primaryLabel(block: block(), sessionLabel: nil), "Rex session")
        XCTAssertEqual(RexRows.primaryLabel(block: block(window: " \u{202E} ", label: nil), sessionLabel: " S\n1 "), "S 1")
    }

    func testAgentLabelPrefersTitleThenApp() {
        XCTAssertEqual(RexRows.agentLabel(record("done", app: "claude-code", title: "Review")), "Review")
        XCTAssertEqual(RexRows.agentLabel(record("done", app: "claude-code", title: " ")), "claude-code")
        XCTAssertNil(RexRows.agentLabel(record("done")))
    }

    func testSubtitlePrefersMessageThenAgentLabelThenState() {
        XCTAssertEqual(RexRows.subtitle(record("blocked", app: "pi", msg: "Allow rm -rf\nbuild?")), "blocked · Allow rm -rf build?")
        XCTAssertEqual(RexRows.subtitle(record("done", app: "claude-code")), "done · claude-code")
        XCTAssertEqual(RexRows.subtitle(record("working")), "working")
    }

    // MARK: Ranking

    func testRankingBlockedOverWorkingOverErrorOverDone() {
        let records = [
            RexRankedRecord(record: record("done", id: "d"), epoch: 9),
            RexRankedRecord(record: record("error", id: "e"), epoch: 8),
            RexRankedRecord(record: record("working", id: "w"), epoch: 1),
        ]
        XCTAssertEqual(RexRows.decidingRecord(records)?.record.id, "w")
        XCTAssertEqual(RexRows.decidingRecord(records + [RexRankedRecord(record: record("blocked", id: "b"), epoch: 0)])?.record.id, "b")
        XCTAssertEqual(RexRows.decidingRecord(Array(records.prefix(2)))?.record.id, "e")
    }

    func testRankingTiesGoToHigherEpochAndIgnoresIdleAndUnknown() {
        let records = [
            RexRankedRecord(record: record("done", id: "old"), epoch: 2),
            RexRankedRecord(record: record("done", id: "new"), epoch: 5),
            RexRankedRecord(record: record("idle", id: "i"), epoch: 7),
            RexRankedRecord(record: record("thinking", id: "u"), epoch: 8),
        ]
        XCTAssertEqual(RexRows.decidingRecord(records)?.record.id, "new")
        XCTAssertNil(RexRows.decidingRecord(Array(records.suffix(2))))
    }

    func testRowMapsStatesAndCarriesToken() throws {
        let token = SeenToken(marks: ["x"])
        let row = try XCTUnwrap(RexRows.row(
            session: session, block: block(window: "Review"), sessionLabel: "S",
            visibleRecords: [RexRankedRecord(record: record("done", app: "claude-code"), epoch: 1)],
            seenToken: token
        ))
        XCTAssertEqual(row, AgentRow(target: AgentTarget(session: session, paneID: "block:1"), displayLabel: "Review",
                                     agentLabel: "claude-code", state: .finished, subtitle: "done · claude-code", seenToken: token))

        func state(_ s: String) -> RowState? {
            RexRows.row(session: session, block: block(), sessionLabel: nil,
                        visibleRecords: [RexRankedRecord(record: record(s), epoch: 1)], seenToken: nil)?.state
        }
        XCTAssertEqual(state("blocked"), .attention(.blocked))
        XCTAssertEqual(state("error"), .attention(.error))
        XCTAssertEqual(state("working"), .working)
        XCTAssertNil(state("idle"))
        XCTAssertNil(RexRows.row(session: session, block: block(), sessionLabel: nil, visibleRecords: [], seenToken: nil))
    }
}
