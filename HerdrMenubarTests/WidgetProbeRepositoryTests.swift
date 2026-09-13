import Foundation
import XCTest
@testable import HerdrMenubar

final class WidgetProbeRepositoryTests: XCTestCase {
    private func withRepository(_ body: (WidgetProbeRepository, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("probe.json")
        try body(WidgetProbeRepository(url: url), url)
    }

    func testRoundTripAndReplacement() throws {
        try withRepository { repository, _ in
            let first = WidgetProbeSnapshot(schemaVersion: 1, generation: UUID(), sequence: 1, writtenAt: Date(timeIntervalSince1970: 100))
            try repository.write(first)
            XCTAssertEqual(try repository.read(), first)
            let second = WidgetProbeSnapshot(schemaVersion: 1, generation: UUID(), sequence: 2, writtenAt: Date(timeIntervalSince1970: 101))
            try repository.write(second)
            XCTAssertEqual(try repository.read(), second)
        }
    }

    func testMissingAndMalformedSnapshotsFail() throws {
        try withRepository { repository, url in
            XCTAssertThrowsError(try repository.read())
            try Data("invalid".utf8).write(to: url)
            XCTAssertThrowsError(try repository.read())
        }
    }

    func testUnsupportedVersionFailsInsteadOfShowingStaleSuccess() throws {
        try withRepository { repository, _ in
            try repository.write(WidgetProbeSnapshot(schemaVersion: 2, generation: UUID(), sequence: 1, writtenAt: .now))
            XCTAssertThrowsError(try repository.read())
        }
    }

    func testFutureAndExpiredSnapshotsAreNotFresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = WidgetProbeSnapshot(schemaVersion: 1, generation: UUID(), sequence: 1, writtenAt: now)
        XCTAssertTrue(snapshot.isFresh(at: now))
        XCTAssertTrue(snapshot.isFresh(at: now.addingTimeInterval(89)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(90)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(-1)))
    }
}
