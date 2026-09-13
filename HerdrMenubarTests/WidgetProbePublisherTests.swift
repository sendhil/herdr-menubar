import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class WidgetProbePublisherTests: XCTestCase {
    func testReloadHappensOnlyAfterSuccessfulWrite() throws {
        var stored: WidgetProbeSnapshot?
        var reloaded: WidgetProbeSnapshot?
        let publisher = WidgetProbePublisher(write: { stored = $0 }, reload: { reloaded = stored })
        try publisher.publish(sequence: 1, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(stored?.sequence, 1)
        XCTAssertEqual(reloaded, stored)
    }

    func testWriteFailureDoesNotRequestReload() {
        var reloadCount = 0
        let publisher = WidgetProbePublisher(write: { _ in throw CocoaError(.fileWriteNoPermission) }, reload: { reloadCount += 1 })
        XCTAssertThrowsError(try publisher.publish(sequence: 1, now: .now))
        XCTAssertEqual(reloadCount, 0)
    }

    func testProbeIsOptInAndSuppressedInTests() {
        XCTAssertFalse(WidgetProbePublisher.shouldRun(arguments: [], environment: [:]))
        XCTAssertTrue(WidgetProbePublisher.shouldRun(arguments: ["--widget-refresh-probe"], environment: [:]))
        XCTAssertFalse(WidgetProbePublisher.shouldRun(arguments: ["--widget-refresh-probe"], environment: ["XCTestConfigurationFilePath": "test"]))
    }
}
