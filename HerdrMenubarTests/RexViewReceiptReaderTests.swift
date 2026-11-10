import XCTest
@testable import HerdrMenubar

final class RexViewReceiptReaderTests: XCTestCase {
    private func entry(_ block: Any = "block:1", _ record: Any = "", _ date: Any = Date(timeIntervalSince1970: 1_794_340_072.177)) -> [String: Any] {
        ["block": block, "record": record, "date": date, "message": "PRIVATE"]
    }

    func testParsesBlockRecordAndMillisecondDateIgnoringOtherFields() throws {
        let parsed = try XCTUnwrap(RexViewReceiptParser.parse(["receipts": [entry()]]))
        XCTAssertEqual(parsed, [RexViewReceipt(blockID: "block:1", recordID: "", millis: 1_794_340_072_177)])
    }

    func testMalformedOrOversizedIsUnavailable() {
        XCTAssertNil(RexViewReceiptParser.parse(nil))
        XCTAssertNil(RexViewReceiptParser.parse("x"))
        XCTAssertNil(RexViewReceiptParser.parse(["receipts": "x"]))
        XCTAssertNil(RexViewReceiptParser.parse(["receipts": [entry(5)]]))
        XCTAssertNil(RexViewReceiptParser.parse(["receipts": [entry("b", "", "date")]]))
        XCTAssertNil(RexViewReceiptParser.parse(["receipts": [entry("b", "", Date(timeIntervalSince1970: .infinity))]]))
        XCTAssertNil(RexViewReceiptParser.parse(["receipts": Array(repeating: entry(), count: RexViewReceiptParser.maxReceipts + 1)]))
        XCTAssertNotNil(RexViewReceiptParser.parse(["receipts": [Any]()]))
    }
}
