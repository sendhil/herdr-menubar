import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class WezTermSubprocessIntegrationTests: XCTestCase {
    func testLiveCLIListsAndActivatesThroughExactBundleSibling() async throws {
        let application = try SubprocessWezTermApplication()
        defer { application.remove() }
        try application.setPanes([
            WezTermPane(windowID: 11, tabID: 22, paneID: 33, title: "target")
        ])
        let pids = IntegrationPIDRecorder()
        let cli = await MainActor.run {
            LiveWezTermCLI(
                runner: BoundedProcessRunner(launchObserver: pids.record),
                bundleURL: { application.appURL }
            )
        }

        let panes = try await cli.listPanes()
        try await cli.activatePane(id: 33)

        XCTAssertEqual(panes, [
            WezTermPane(windowID: 11, tabID: 22, paneID: 33, title: "target")
        ])
        XCTAssertEqual(try application.activationIDs(), [33])
        XCTAssertEqual(try application.arguments(), [
            "cli", "list", "--format", "json",
            "cli", "activate-pane", "--pane-id", "33"
        ])
        assertReaped(pids.values)
    }

    func testLiveAdapterPollsFakeCLIThenClearsAndActivates() async throws {
        let application = try SubprocessWezTermApplication()
        defer { application.remove() }
        try application.delayFirstList()
        let pids = IntegrationPIDRecorder()
        let supervisor = SubprocessTitleSupervisor(application: application, paneID: 73)
        let cli = await MainActor.run {
            LiveWezTermCLI(
                runner: BoundedProcessRunner(launchObserver: pids.record),
                bundleURL: { application.appURL }
            )
        }
        let adapter = await MainActor.run {
            LiveWezTermFocusAdapter(
                supervisor: supervisor,
                cli: cli,
                markerGenerator: { "herdr-menubar-focus:integration" }
            )
        }

        try await adapter.focusAttachedClient(sessionID: .named("work"))

        let titleActions = await supervisor.titleActions
        XCTAssertEqual(titleActions, [
            .set("herdr-menubar-focus:integration"), .clear
        ])
        XCTAssertEqual(try application.activationIDs(), [73])
        XCTAssertEqual(try application.listCount(), 2)
        assertReaped(pids.values)
    }

    func testLiveCLIReapsTimedOutFakeProcess() async {
        let application: SubprocessWezTermApplication
        do {
            application = try SubprocessWezTermApplication()
            try application.hangListProcess()
        } catch {
            return XCTFail("Could not create fake WezTerm app: \(error)")
        }
        defer { application.remove() }
        let pids = IntegrationPIDRecorder()
        let cli = await MainActor.run {
            LiveWezTermCLI(
                runner: BoundedProcessRunner(launchObserver: pids.record),
                bundleURL: { application.appURL }
            )
        }

        do {
            _ = try await cli.listPanes(timeout: .milliseconds(40))
            XCTFail("Expected the fake CLI to time out")
        } catch let error as WezTermCLIError {
            XCTAssertEqual(error, .controlFailed)
        } catch {
            XCTFail("Expected WezTermCLIError.controlFailed, got \(error)")
        }

        XCTAssertEqual(pids.values.count, 1)
        assertReaped(pids.values)
    }

    private func assertReaped(
        _ pids: [Int32],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(pids.isEmpty, file: file, line: line)
        for pid in pids {
            errno = 0
            XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }
    }
}

private enum IntegrationWindowTitleAction: Equatable, Sendable {
    case set(String)
    case clear
}

private actor SubprocessTitleSupervisor: SessionSupervising {
    private let application: SubprocessWezTermApplication
    private let paneID: Int
    private(set) var titleActions: [IntegrationWindowTitleAction] = []

    init(application: SubprocessWezTermApplication, paneID: Int) {
        self.application = application
        self.paneID = paneID
    }

    func events() -> AsyncStream<SessionSupervisorEvent> {
        AsyncStream { $0.finish() }
    }

    func start() {}
    func stop() {}
    func retryUnavailable() {}

    func focus(sessionID: SessionID, paneID: String) throws -> PaneInfo {
        throw SessionSupervisorError.sessionUnavailable(sessionID.displayName)
    }

    func setClientWindowTitle(
        sessionID: SessionID,
        title: String
    ) throws -> ClientWindowTitleResult {
        titleActions.append(.set(title))
        try application.setPanes([
            WezTermPane(windowID: 1, tabID: 2, paneID: paneID, title: title)
        ])
        return ClientWindowTitleResult(
            type: "client_window_title",
            changed: true,
            reason: "set"
        )
    }

    func clearClientWindowTitle(
        sessionID: SessionID,
        timeout: Duration
    ) throws -> ClientWindowTitleResult {
        titleActions.append(.clear)
        try application.setPanes([
            WezTermPane(windowID: 1, tabID: 2, paneID: paneID, title: "restored")
        ])
        return ClientWindowTitleResult(
            type: "client_window_title",
            changed: true,
            reason: "cleared"
        )
    }

    func refresh(sessionID: SessionID) {}
}

private final class IntegrationPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var values: [Int32] {
        lock.withLock { storage }
    }

    func record(_ pid: Int32) {
        lock.withLock { storage.append(pid) }
    }
}

private final class SubprocessWezTermApplication: @unchecked Sendable {
    let rootURL: URL
    let appURL: URL

    private let executableURL: URL
    private let panesURL: URL
    private let argumentsURL: URL
    private let activationsURL: URL
    private let listCountURL: URL
    private let delayFirstURL: URL
    private let hangURL: URL

    init() throws {
        rootURL = try Self.makeTemporaryRoot()
        appURL = rootURL.appending(path: "WezTerm.app", directoryHint: .isDirectory)
        let executableDirectory = appURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        executableURL = executableDirectory.appending(path: "wezterm")
        panesURL = executableDirectory.appending(path: "panes.json")
        argumentsURL = executableDirectory.appending(path: "arguments.log")
        activationsURL = executableDirectory.appending(path: "activations.log")
        listCountURL = executableDirectory.appending(path: "list-count")
        delayFirstURL = executableDirectory.appending(path: "delay-first")
        hangURL = executableDirectory.appending(path: "hang")

        do {
            try FileManager.default.createDirectory(
                at: executableDirectory,
                withIntermediateDirectories: true
            )
            try Data(Self.script.utf8).write(to: executableURL)
            guard chmod(executableURL.path, 0o700) == 0 else {
                throw POSIXError(.EACCES)
            }
            try Data("[]".utf8).write(to: panesURL)
        } catch {
            remove()
            throw error
        }
    }

    func setPanes(_ panes: [WezTermPane]) throws {
        let objects = panes.map { pane in
            [
                "window_id": pane.windowID,
                "tab_id": pane.tabID,
                "pane_id": pane.paneID,
                "title": pane.title
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        try data.write(to: panesURL, options: .atomic)
    }

    func delayFirstList() throws {
        try Data().write(to: delayFirstURL)
    }

    func hangListProcess() throws {
        try Data().write(to: hangURL)
    }

    func arguments() throws -> [String] {
        try lines(at: argumentsURL)
    }

    func activationIDs() throws -> [Int] {
        try lines(at: activationsURL).compactMap(Int.init)
    }

    func listCount() throws -> Int {
        Int(try String(contentsOf: listCountURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func lines(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private static func makeTemporaryRoot() throws -> URL {
        for _ in 0..<20 {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
                .lowercased()
            let url = URL(fileURLWithPath: "/tmp/hm-wz-\(suffix)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private static let script = """
    #!/bin/sh
    state_dir=${0%/wezterm}/
    printf '%s\\n' "$@" >> "${state_dir}arguments.log"

    if [ "$#" -eq 4 ] && [ "$1" = "cli" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
        if [ -f "${state_dir}hang" ]; then
            trap '' TERM
            while :; do :; done
        fi
        count=0
        if [ -f "${state_dir}list-count" ]; then
            read -r count < "${state_dir}list-count"
        fi
        count=$((count + 1))
        printf '%s\\n' "$count" > "${state_dir}list-count"
        if [ -f "${state_dir}delay-first" ] && [ "$count" -eq 1 ]; then
            printf '[]'
        else
            /bin/cat "${state_dir}panes.json"
        fi
        exit 0
    fi

    if [ "$#" -eq 4 ] && [ "$1" = "cli" ] && [ "$2" = "activate-pane" ] && [ "$3" = "--pane-id" ]; then
        printf '%s\\n' "$4" >> "${state_dir}activations.log"
        exit 0
    fi

    printf 'unexpected fake wezterm arguments\\n' >&2
    exit 64
    """
}
