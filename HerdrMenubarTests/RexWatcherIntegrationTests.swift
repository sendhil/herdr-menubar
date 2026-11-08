import Synchronization
import XCTest
@testable import HerdrMenubar

/// The bundled script itself, plus one read-only run against the live Rex server.
final class RexWatcherIntegrationTests: XCTestCase {
    func testWatcherScriptIsBundledAndMatchesTheSpec() throws {
        let url = try XCTUnwrap(RexWatcherScript.bundledURL(), "RexWatcher.lua missing from the app bundle")
        let bundled = try String(contentsOf: url, encoding: .utf8)

        let specURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/superpowers/specs/2026-11-07-rex-backend-design.md")
        let spec = try String(contentsOf: specURL, encoding: .utf8)
        let section = try XCTUnwrap(spec.range(of: "Bundled as `RexWatcher.lua`"))
        let start = try XCTUnwrap(spec.range(of: "```lua\n", range: section.upperBound..<spec.endIndex))
        let end = try XCTUnwrap(spec.range(of: "\n```", range: start.upperBound..<spec.endIndex))
        XCTAssertEqual(bundled, String(spec[start.upperBound..<end.lowerBound]) + "\n")
    }

    func testWatcherArguments() {
        XCTAssertEqual(RexWatcherScript.arguments(scriptPath: "/a b/RexWatcher.lua"),
                       ["--autostart=false", "do", "/a b/RexWatcher.lua", "--all"])
        let process = RexWatcherScript.makeProcess(cli: RexCLI(path: "/x/rex", version: "v", apiRevision: 10),
                                                   scriptURL: URL(fileURLWithPath: "/s/RexWatcher.lua"), generation: 3)
        XCTAssertEqual(process.executable, "/x/rex")
        XCTAssertEqual(process.generation, 3)
        XCTAssertEqual(process.stdoutMode, .lines(maxLineLength: ManagedProcess.watcherMaxLineLength))
        XCTAssertFalse(process.environment.keys.contains { $0.hasPrefix("REX_") })
    }

    /// Read-only: the watcher only lists sessions, views and program status. Skipped when no
    /// valid Rex CLI resolves, the server is not running, or `HERDR_MENUBAR_SKIP_LIVE_REX` is set
    /// (pass it through xcodebuild as `TEST_RUNNER_HERDR_MENUBAR_SKIP_LIVE_REX=1`).
    func testBundledWatcherSnapshotsTheLiveServer() async throws {
        if ProcessInfo.processInfo.environment["HERDR_MENUBAR_SKIP_LIVE_REX"] != nil {
            throw XCTSkip("HERDR_MENUBAR_SKIP_LIVE_REX is set")
        }
        // No shell probe from tests.
        let resolution = try await RexCLIResolver(configuredPath: nil, isRexAppInstalled: { false }).resolve()
        guard case .ready(let cli) = resolution else {
            throw XCTSkip("No valid Rex CLI with a reachable server: \(resolution)")
        }
        let scriptURL = try XCTUnwrap(RexWatcherScript.bundledURL())
        let process = RexWatcherScript.makeProcess(cli: cli, scriptURL: scriptURL, generation: 1)
        let stream = try process.start()

        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            await process.terminate()
        }
        defer { deadline.cancel() }

        var lines: [RexWatcherLine] = []
        var other: [ManagedProcessEvent] = []
        for await event in stream {
            switch event {
            case .line(let generation, let data):
                XCTAssertEqual(generation, 1)
                lines.append(try RexWatcherLine.decode(data))
                if lines.last == .snapshotDone { await process.terminate() }
            case .framingError, .exited:
                other.append(event)
            }
        }

        XCTAssertTrue(lines.contains(.snapshotDone), "no snapshot_done within 20 s; stderr: \(process.stderrTail)")
        XCTAssertEqual(other.count, 1, "\(other)")
        guard case .exited(_, let termination) = other.last else { return XCTFail("\(other)") }
        XCTAssertTrue(termination.terminatedByUs)

        // Only the snapshot is checked: events queued during it may legitimately arrive after
        // `snapshot_done` (with `via`, or as a status_error) while the user's agents are busy.
        let doneIndex = try XCTUnwrap(lines.firstIndex(of: .snapshotDone))
        let snapshot = lines[...doneIndex]
        let announced = Set(snapshot.compactMap { if case .session(let id, _) = $0 { id } else { nil } })
        for line in snapshot {
            switch line {
            case .view(let view): XCTAssertTrue(announced.contains(view.sessionID))
            case .block(let read):
                XCTAssertTrue(announced.contains(read.sessionID))
                XCTAssertNil(read.via, "snapshot reads carry no via")
                XCTAssertTrue(read.records.allSatisfy { $0.updatedAt != nil }, "\(read)")
            case .unknown, .statusError, .viewError, .snapshotError, .encodeError:
                XCTFail("unexpected line during snapshot: \(line)")
            default: break
            }
        }
    }
}
