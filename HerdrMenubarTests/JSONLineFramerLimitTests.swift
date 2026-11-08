import XCTest
@testable import HerdrMenubar

final class JSONLineFramerLimitTests: XCTestCase {
    private func lines(_ strings: String...) -> [Data] { strings.map { Data($0.utf8) } }

    func testDefaultFramerHasNoLimitAndUncheckedAppendIgnoresLength() throws {
        var framer = JSONLineFramer()
        XCTAssertNil(framer.maxLineLength)
        let long = Data(repeating: 0x61, count: 10_000)
        XCTAssertEqual(framer.append(long + Data([0x0A])), [long])
        let output = framer.appendLines(long + Data([0x0A]))
        XCTAssertEqual(output.lines, [long])
        XCTAssertNil(output.error)
    }

    func testLimitedFramerAcceptsLinesUpToTheLimit() throws {
        var framer = JSONLineFramer(maxLineLength: 4)
        XCTAssertEqual(framer.appendLines(Data("abcd\r\nab".utf8)).lines, lines("abcd"))
        let second = framer.appendLines(Data("cd\n".utf8))
        XCTAssertEqual(second.lines, lines("abcd"))
        XCTAssertNil(second.error)
        XCTAssertNoThrow(try framer.finish())
    }

    func testCompleteLinesBeforeAnOverCapLineInOneAppendAreDeliveredThenTheErrorRaised() {
        var framer = JSONLineFramer(maxLineLength: 4)
        let output = framer.appendLines(Data("ok\nfine\nabcde\nlater\n".utf8))
        XCTAssertEqual(output.lines, lines("ok", "fine"))
        XCTAssertEqual(output.error, .lineTooLong(limit: 4))

        let next = framer.appendLines(Data("x\n".utf8))
        XCTAssertEqual(next.lines, [])
        XCTAssertEqual(next.error, .lineTooLong(limit: 4))
    }

    func testCompleteLinesBeforeAnOverCapPartialLineInOneAppendAreDelivered() {
        var framer = JSONLineFramer(maxLineLength: 4)
        let output = framer.appendLines(Data("ok\nabcdef".utf8))
        XCTAssertEqual(output.lines, lines("ok"))
        XCTAssertEqual(output.error, .lineTooLong(limit: 4))
    }

    func testLimitedFramerFailsAsSoonAsAPartialLineExceedsTheLimit() throws {
        var framer = JSONLineFramer(maxLineLength: 4)
        let first = framer.appendLines(Data("abc".utf8))
        XCTAssertEqual(first.lines, [])
        XCTAssertNil(first.error)
        XCTAssertEqual(framer.appendLines(Data("de".utf8)).error, .lineTooLong(limit: 4))
    }

    func testOverflowIsStickyAndDropsBufferedData() {
        var framer = JSONLineFramer(maxLineLength: 2)
        XCTAssertEqual(framer.appendLines(Data("abc".utf8)).error, .lineTooLong(limit: 2))
        let later = framer.appendLines(Data("\nok\n".utf8))
        XCTAssertEqual(later.lines, [])
        XCTAssertEqual(later.error, .lineTooLong(limit: 2))
        XCTAssertThrowsError(try framer.finish()) { error in
            XCTAssertEqual(error as? FramingError, .lineTooLong(limit: 2))
        }
    }

    func testCarriageReturnDoesNotCountTowardTheLimit() throws {
        var framer = JSONLineFramer(maxLineLength: 2)
        let output = framer.appendLines(Data("ab\r\n".utf8))
        XCTAssertEqual(output.lines, lines("ab"))
        XCTAssertNil(output.error)
    }
}
