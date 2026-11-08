import XCTest
@testable import HerdrMenubar

final class JSONLineFramerLimitTests: XCTestCase {
    func testDefaultFramerHasNoLimitAndUncheckedAppendIgnoresLength() throws {
        var framer = JSONLineFramer()
        XCTAssertNil(framer.maxLineLength)
        let long = Data(repeating: 0x61, count: 10_000)
        XCTAssertEqual(framer.append(long + Data([0x0A])), [long])
        XCTAssertEqual(try framer.appendLines(long + Data([0x0A])), [long])
    }

    func testLimitedFramerAcceptsLinesUpToTheLimit() throws {
        var framer = JSONLineFramer(maxLineLength: 4)
        XCTAssertEqual(try framer.appendLines(Data("abcd\r\nab".utf8)), [Data("abcd".utf8)])
        XCTAssertEqual(try framer.appendLines(Data("cd\n".utf8)), [Data("abcd".utf8)])
        XCTAssertNoThrow(try framer.finish())
    }

    func testLimitedFramerThrowsForACompleteLineOverTheLimit() {
        var framer = JSONLineFramer(maxLineLength: 4)
        XCTAssertThrowsError(try framer.appendLines(Data("ok\nabcde\n".utf8))) { error in
            XCTAssertEqual(error as? FramingError, .lineTooLong(limit: 4))
        }
    }

    func testLimitedFramerThrowsAsSoonAsAPartialLineExceedsTheLimit() throws {
        var framer = JSONLineFramer(maxLineLength: 4)
        XCTAssertEqual(try framer.appendLines(Data("abc".utf8)), [])
        XCTAssertThrowsError(try framer.appendLines(Data("de".utf8))) { error in
            XCTAssertEqual(error as? FramingError, .lineTooLong(limit: 4))
        }
    }

    func testOverflowIsStickyAndDropsBufferedData() {
        var framer = JSONLineFramer(maxLineLength: 2)
        XCTAssertThrowsError(try framer.appendLines(Data("abc".utf8)))
        XCTAssertThrowsError(try framer.appendLines(Data("\nok\n".utf8))) { error in
            XCTAssertEqual(error as? FramingError, .lineTooLong(limit: 2))
        }
        XCTAssertThrowsError(try framer.finish()) { error in
            XCTAssertEqual(error as? FramingError, .lineTooLong(limit: 2))
        }
    }

    func testCarriageReturnDoesNotCountTowardTheLimit() throws {
        var framer = JSONLineFramer(maxLineLength: 2)
        XCTAssertEqual(try framer.appendLines(Data("ab\r\n".utf8)), [Data("ab".utf8)])
    }
}
