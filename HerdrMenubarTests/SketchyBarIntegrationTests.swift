import AppKit
import XCTest
@testable import HerdrMenubar

@MainActor
final class SketchyBarIntegrationTests: XCTestCase {
    func testPublisherDeduplicatesRetriesAndMarksStopped() throws {
        var records: [SketchyBarSnapshot] = []
        var notifications = 0
        var time = 100.0
        var fail = false
        let publisher = SketchyBarStatusPublisher(now: { time }, write: {
            if fail { throw CocoaError(.fileWriteUnknown) }
            records.append($0)
        }, notify: { notifications += 1 }, automaticHeartbeat: false)
        publisher.start()
        publisher.apply(snapshot(2))
        publisher.apply(snapshot(2))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.last?.attentionCount, 2)
        XCTAssertEqual(records.last?.mode, "attention")
        fail = true
        publisher.apply(snapshot(3))
        XCTAssertEqual(notifications, 1)
        fail = false
        publisher.apply(snapshot(3))
        XCTAssertEqual(records.count, 2)
        time = 130
        publisher.heartbeat()
        XCTAssertEqual(records.last?.writtenAt, 130)
        publisher.stop()
        XCTAssertEqual(records.last?.isRunning, false)
        let finalCount = records.count
        publisher.apply(snapshot(9))
        publisher.heartbeat()
        publisher.start()
        publisher.stop()
        XCTAssertEqual(records.count, finalCount)
        XCTAssertEqual(notifications, records.count)
    }

    func testAtomicFileIsPrivateAndDecodable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let record = SketchyBarSnapshot(writtenAt: 100, isRunning: true, mode: "clear", attentionCount: 0, summary: "Connected")
        try SketchyBarStatusPublisher.write(record, to: file)
        try SketchyBarStatusPublisher.write(record, to: file)
        XCTAssertEqual(try JSONDecoder().decode(SketchyBarSnapshot.self, from: Data(contentsOf: file)), record)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
    }

    func testDetachedMenuFreezesCurrentNodesAndRejectsLateActions() {
        var menus: [[StatusMenuNode]] = []
        var callbacks: [(StatusMenuAction) -> Void] = []
        var cancellations = 0
        var actions: [StatusMenuAction] = []
        var controller: DetachedMenuController!
        controller = DetachedMenuController(show: { nodes, action in
            menus.append(nodes)
            callbacks.append(action)
            if menus.count == 1 {
                controller.apply(snapshot(3))
                controller.show()
                action(.quit)
            }
        }, cancel: { cancellations += 1 }, action: { actions.append($0) })
        controller.apply(snapshot(2))
        controller.show()
        XCTAssertEqual(menus, [snapshot(2).menu])
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(actions, [.quit])
        callbacks[0](.quit)
        XCTAssertEqual(actions.count, 1)
        controller.show()
        XCTAssertEqual(menus.last, snapshot(3).menu)
        controller.stop()
        callbacks[1](.quit)
        controller.show()
        XCTAssertEqual(menus.count, 2)
        XCTAssertEqual(actions.count, 1)
    }
}

@MainActor
private func snapshot(_ count: Int) -> StatusItemPresentation {
    StatusItemPresentation(icon: MenuBarIconPresentation(connectionState: .connected, attentionCount: count), accessibilityValue: "Connected", menu: [.heading("Count \(count)")])
}
