import XCTest
@testable import HerdrMenubar

final class JSONLineFramerTests: XCTestCase {
    func testHandlesOneLineSplitAcrossReadsAndMultipleLines() throws {
        var framer = JSONLineFramer()

        XCTAssertEqual(framer.append(Data(#"{"id":"1""#.utf8)), [])
        XCTAssertEqual(
            framer.append(Data("}\n{\"id\":\"2\"}\n".utf8)),
            [Data(#"{"id":"1"}"#.utf8), Data(#"{"id":"2"}"#.utf8)]
        )
        XCTAssertNoThrow(try framer.finish())
    }

    func testDropsBlankLinesAndStripsCarriageReturnFromCRLF() throws {
        var framer = JSONLineFramer()

        XCTAssertEqual(
            framer.append(Data("\n\r\n{\"ok\":true}\r\n\n".utf8)),
            [Data(#"{"ok":true}"#.utf8)]
        )
        XCTAssertNoThrow(try framer.finish())
    }

    func testFinishAllowsTrailingWhitespace() {
        var framer = JSONLineFramer()
        XCTAssertEqual(framer.append(Data(" \t\r".utf8)), [])
        XCTAssertNoThrow(try framer.finish())
    }

    func testFinishRejectsIncompleteNonWhitespaceLine() {
        var framer = JSONLineFramer()
        XCTAssertEqual(framer.append(Data(#"{"id":"1"}"#.utf8)), [])

        XCTAssertThrowsError(try framer.finish()) { error in
            XCTAssertEqual(error as? FramingError, .incompleteLine)
        }
    }
}
