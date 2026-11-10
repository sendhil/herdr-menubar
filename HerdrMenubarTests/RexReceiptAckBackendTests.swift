import XCTest
@testable import HerdrMenubar

final class FakeReceiptReader: RexViewReceiptReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _receipts: [RexViewReceipt]?
    private var _reads = 0
    init(_ receipts: [RexViewReceipt]? = []) { _receipts = receipts }
    var reads: Int { lock.withLock { _reads } }
    func set(_ receipts: [RexViewReceipt]?) { lock.withLock { _receipts = receipts } }
    func readReceipts() -> [RexViewReceipt]? { lock.withLock { _reads += 1; return _receipts } }
}

@MainActor
final class RexReceiptAckBackendTests: XCTestCase {
    private let cli = RexCLI(path: "/rex/Current/rex", version: "0.0.1", apiRevision: 10)
    private var clock: ManualRexClock!
    private var watchers: FakeWatcherFactory!
    private var backend: RexBackend!
    private var recorder: BackendEventRecorder!

    override func setUp() {
        super.setUp()
        clock = ManualRexClock()
        watchers = FakeWatcherFactory()
    }

    override func tearDown() async throws {
        await backend?.stop()
        backend = nil
        try await super.tearDown()
    }

    private func start(reader: (any RexViewReceiptReading)?) async {
        backend = RexBackend(resolver: FakeRexResolver([.ready(cli)]), scriptURL: URL(fileURLWithPath: "/x.lua"),
                             makeWatcher: watchers.factory, runner: ScriptedProcessRunner(), app: FakeRexApp(),
                             clock: clock, hostName: { "Mac" }, receiptReader: reader, isEnabled: { true })
        recorder = BackendEventRecorder(await backend.events())
        await backend.start()
        await rexWaitUntil("process") { watchers.processes.first?.started == true }
        watchers.last!.send(RexJSON.snapshot(state: "done", at: 1))
        await rexWaitUntil("connected") { recorder.events.contains { if case .connected = $0 { true } else { false } } }
    }

    private func latestRows() -> Int? {
        for event in recorder.events.reversed() {
            if let (_, snapshot) = event.snapshotPayload { return snapshot.rows.count }
            if case .connected(_, let snapshot) = event { return snapshot.rows.count }
        }
        return nil
    }

    private var match: RexViewReceipt { RexViewReceipt(blockID: "b1", recordID: "", millis: RexLines.micros(1) / 1000) }

    func testReceiptHidesTheRowWithinOnePollInterval() async {
        let reader = FakeReceiptReader([])
        await start(reader: reader)
        XCTAssertEqual(latestRows(), 1)
        reader.set([match])
        await rexWaitUntil("poll sleeper") { clock.sleeperCount > 0 }
        clock.advance(.seconds(1))
        await rexWaitUntil("hidden") { latestRows() == 0 }
    }

    func testPresentReceiptAtStartupHidesExistingDone() async {
        await start(reader: FakeReceiptReader([match]))
        await rexWaitUntil("hidden") { latestRows() == 0 }
    }

    func testNoReaderNeverHides() async {
        await start(reader: nil)
        clock.advance(.seconds(5))
        await settleTasks()
        XCTAssertEqual(latestRows(), 1)
    }

    func testUnavailableReaderKeepsTheRow() async {
        let reader = FakeReceiptReader(nil)
        await start(reader: reader)
        await rexWaitUntil("read") { reader.reads > 0 }
        clock.advance(.seconds(3))
        await settleTasks()
        XCTAssertEqual(latestRows(), 1)
    }

    func testClearFinishedStillWorksWithReader() async {
        await start(reader: FakeReceiptReader([]))
        await backend.clearFinished()
        await rexWaitUntil("cleared") { latestRows() == 0 }
    }
}
