import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class MultiSessionIntegrationTests: XCTestCase {
    func testTwoServersBootstrapUpdateAndFocusIndependently() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultServer = try FakeHerdrServer(
            url: root.appending(path: "herdr.sock"),
            panes: [integrationPane("duplicate", .done)]
        )
        defer { defaultServer.stop() }
        let namedServer = try FakeHerdrServer(
            url: root.appending(path: "sessions/work/herdr.sock"),
            panes: [integrationPane("duplicate", .working)]
        )
        defer { namedServer.stop() }

        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: IntegrationHoldingSleeper(),
            discoveryInterval: .seconds(30)
        )
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let focuser = await MainActor.run { IntegrationRecordingWezTermFocuser() }
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: focuser
            )
        }
        await store.start()

        await eventually {
            await MainActor.run {
                store.attentionCount == 1 && store.workingSections.count == 1
            }
        }
        let initialIDs = await MainActor.run {
            (store.attentionSections.flatMap(\.items) + store.workingSections.flatMap(\.items))
                .map(\.id)
        }
        XCTAssertEqual(Set(initialIDs), [
            AgentMenuItemID(sessionID: .default, paneID: "duplicate"),
            AgentMenuItemID(sessionID: .named("work"), paneID: "duplicate")
        ])

        await namedServer.setPanes([integrationPane("duplicate", .blocked)])
        await namedServer.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
        await eventually {
            await MainActor.run { store.attentionCount == 2 }
        }

        let namedItem = await MainActor.run {
            store.attentionSections.first { $0.id == .named("work") }?.items.first
        }
        guard let namedItem else {
            XCTFail("Expected one named-session attention item")
            await store.stop()
            return
        }
        await store.select(namedItem)
        let namedFocused = await namedServer.focusedPaneIDs
        let defaultFocused = await defaultServer.focusedPaneIDs
        XCTAssertEqual(namedFocused, ["duplicate"])
        XCTAssertEqual(defaultFocused, [])
        await store.stop()
    }

    func testDuplicatePaneIDsFocusOwningHerdrServerAndOwningWezTermPane() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultServer = try FakeHerdrServer(
            url: root.appending(path: "herdr.sock"),
            panes: [integrationPane("duplicate", .done)]
        )
        defer { defaultServer.stop() }
        let namedServer = try FakeHerdrServer(
            url: root.appending(path: "sessions/work/herdr.sock"),
            panes: [integrationPane("duplicate", .done)]
        )
        defer { namedServer.stop() }

        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: IntegrationHoldingSleeper(),
            discoveryInterval: .seconds(30)
        )
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let wezTermCLI = await MainActor.run {
            IntegrationWezTermCLI(
                defaultServer: defaultServer,
                namedServer: namedServer,
                defaultPaneID: 41,
                namedPaneID: 82
            )
        }
        let wezTermFocuser = await MainActor.run {
            LiveWezTermFocusAdapter(
                supervisor: supervisor,
                cli: wezTermCLI,
                markerGenerator: { "herdr-menubar-focus:integration" }
            )
        }
        let preferencesFixture = try await MainActor.run { try IntegrationPreferencesFixture() }
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: wezTermFocuser,
                preferences: preferencesFixture.preferences
            )
        }
        await store.start()
        await eventually {
            await MainActor.run { store.attentionCount == 2 }
        }

        guard let namedItem = await MainActor.run(body: {
            store.attentionSections.first { $0.id == .named("work") }?.items.first
        }) else {
            await store.stop()
            await MainActor.run { preferencesFixture.remove() }
            return XCTFail("Expected named-session attention item")
        }
        await store.select(namedItem)

        let namedFocused = await namedServer.focusedPaneIDs
        let defaultInitiallyFocused = await defaultServer.focusedPaneIDs
        XCTAssertEqual(namedFocused, ["duplicate"])
        XCTAssertEqual(defaultInitiallyFocused, [])
        let namedActivations = await MainActor.run { wezTermCLI.activatedPaneIDs }
        XCTAssertEqual(namedActivations, [82])
        let namedTitleActions = await namedServer.windowTitleActions
        let defaultInitialTitleActions = await defaultServer.windowTitleActions
        XCTAssertEqual(namedTitleActions, [
            .set("herdr-menubar-focus:integration"), .clear
        ])
        XCTAssertEqual(defaultInitialTitleActions, [])

        guard let defaultItem = await MainActor.run(body: {
            store.attentionSections.first { $0.id == .default }?.items.first
        }) else {
            await store.stop()
            await MainActor.run { preferencesFixture.remove() }
            return XCTFail("Expected default-session attention item")
        }
        await store.select(defaultItem)

        let allActivations = await MainActor.run { wezTermCLI.activatedPaneIDs }
        XCTAssertEqual(allActivations, [82, 41])
        let defaultFocused = await defaultServer.focusedPaneIDs
        let defaultTitleActions = await defaultServer.windowTitleActions
        XCTAssertEqual(defaultFocused, ["duplicate"])
        XCTAssertEqual(defaultTitleActions, [
            .set("herdr-menubar-focus:integration"), .clear
        ])
        await store.stop()
        await MainActor.run { preferencesFixture.remove() }
    }

    func testStoppingOneServerKeepsOtherConnectedAndRestartWithinGraceDoesNotDuplicate() async throws {
        let root = try makeTemporaryHerdrRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultServer = try FakeHerdrServer(
            url: root.appending(path: "herdr.sock"),
            panes: [integrationPane("a", .done)]
        )
        defer { defaultServer.stop() }
        let namedURL = root.appending(path: "sessions/work/herdr.sock")
        var namedServer: FakeHerdrServer? = try FakeHerdrServer(
            url: namedURL,
            panes: [integrationPane("b", .done)]
        )
        defer { namedServer?.stop() }

        let graceSleeper = IntegrationHoldingSleeper()
        let supervisor = SessionSupervisor(
            discovery: SessionDiscovery(configRoot: root),
            clientFactory: IntegrationClientFactory(),
            sleeper: graceSleeper,
            discoveryInterval: .seconds(30),
            removalGracePeriod: .seconds(10)
        )
        let activator = await MainActor.run { IntegrationRecordingActivator() }
        let focuser = await MainActor.run { IntegrationRecordingWezTermFocuser() }
        let store = await MainActor.run {
            AgentStore(
                supervisor: supervisor,
                terminalActivator: activator,
                wezTermFocuser: focuser
            )
        }
        await store.start()
        await eventually {
            await MainActor.run { store.attentionCount == 2 }
        }

        namedServer?.stop()
        namedServer = nil
        await store.retry()
        await eventually {
            await MainActor.run {
                store.attentionCount == 1
                    && store.unavailableSessions.map(\.id) == [.named("work")]
            }
        }
        let stateWhileNamedUnavailable = await MainActor.run { store.connectionState }
        XCTAssertEqual(stateWhileNamedUnavailable, .connected)
        let defaultSectionIDs = await MainActor.run { store.attentionSections.map(\.id) }
        XCTAssertEqual(defaultSectionIDs, [.default])
        let hasPendingGrace = await graceSleeper.hasPendingWait(for: .seconds(10))
        XCTAssertTrue(hasPendingGrace)

        do {
            namedServer = try FakeHerdrServer(
                url: namedURL,
                panes: [integrationPane("b", .done)]
            )
        } catch {
            await store.stop()
            throw error
        }
        await store.retry()
        await eventually {
            await MainActor.run {
                store.attentionCount == 2
                    && store.attentionSections.filter { $0.id == .named("work") }.count == 1
            }
        }
        let namedSectionCount = await MainActor.run {
            store.attentionSections.filter { $0.id == .named("work") }.count
        }
        XCTAssertEqual(namedSectionCount, 1)
        await store.stop()
    }
}

private struct IntegrationClientFactory: SessionClientCreating {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing {
        HerdrClient(
            socketURL: descriptor.socketURL,
            backoff: BackoffPolicy(delays: [.milliseconds(10)], jitter: { 0 }),
            requestTimeout: .milliseconds(250),
            subscriptionRebuildDebounce: .milliseconds(10)
        )
    }
}

@MainActor
private final class IntegrationRecordingActivator: TerminalActivating {
    private(set) var activationCount = 0

    func activate(bundleIdentifier: String) async throws {
        activationCount += 1
    }
}

@MainActor
private final class IntegrationPreferencesFixture {
    let preferences: Preferences

    private let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "dev.herdr.menubar.integration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        preferences = Preferences(defaults: defaults)
        preferences.selectedTerminalBundleIdentifier = WezTermCLIConstants.bundleIdentifier
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class IntegrationRecordingWezTermFocuser: WezTermSessionFocusing {
    private(set) var focusedSessionIDs: [SessionID] = []
    private(set) var forgottenSessionIDs: [SessionID] = []

    func focusAttachedClient(sessionID: SessionID) async throws {
        focusedSessionIDs.append(sessionID)
    }

    func forget(sessionID: SessionID) {
        forgottenSessionIDs.append(sessionID)
    }
}

@MainActor
private final class IntegrationWezTermCLI: WezTermCLIControlling {
    private let defaultServer: FakeHerdrServer
    private let namedServer: FakeHerdrServer
    private let defaultPaneID: Int
    private let namedPaneID: Int
    private(set) var activatedPaneIDs: [Int] = []

    init(
        defaultServer: FakeHerdrServer,
        namedServer: FakeHerdrServer,
        defaultPaneID: Int,
        namedPaneID: Int
    ) {
        self.defaultServer = defaultServer
        self.namedServer = namedServer
        self.defaultPaneID = defaultPaneID
        self.namedPaneID = namedPaneID
    }

    func listPanes(timeout: Duration) async -> [WezTermPane] {
        var panes: [WezTermPane] = []
        if let title = await defaultServer.currentWindowTitle {
            panes.append(WezTermPane(
                windowID: 1,
                tabID: 1,
                paneID: defaultPaneID,
                title: title
            ))
        }
        if let title = await namedServer.currentWindowTitle {
            panes.append(WezTermPane(
                windowID: 1,
                tabID: 2,
                paneID: namedPaneID,
                title: title
            ))
        }
        return panes
    }

    func activatePane(id: Int) {
        activatedPaneIDs.append(id)
    }
}

private actor IntegrationHoldingSleeper: Sleeper {
    private struct Wait {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waits: [Wait] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waits.append(Wait(id: id, duration: duration, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
        waits.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func hasPendingWait(for duration: Duration) -> Bool {
        waits.contains { $0.duration == duration }
    }
}

private func eventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition was not met within one second", file: file, line: line)
}

private func makeTemporaryHerdrRoot() throws -> URL {
    let fileManager = FileManager.default
    for _ in 0..<20 {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let root = URL(fileURLWithPath: "/tmp/hm-\(suffix)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            return root
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            continue
        }
    }
    throw FakeHerdrServerError.temporaryRootCollision
}

private func integrationPane(_ id: String, _ status: AgentStatus) -> PaneInfo {
    PaneInfo(
        paneID: id,
        terminalID: "terminal-\(id)",
        workspaceID: "workspace",
        tabID: "tab",
        focused: false,
        label: "pane-\(id)",
        agent: "claude",
        title: nil,
        displayAgent: "Claude",
        agentStatus: status,
        revision: 1
    )
}

private enum FakeHerdrServerError: Error {
    case temporaryRootCollision
    case socketPathTooLong
    case systemCall(String, Int32)
    case malformedRequest
    case unsupportedMethod(String)
    case missingPane(String)
}

private struct FakeServerRequest: Decodable, Sendable {
    let id: String
    let method: String
    let params: FakeServerRequestParams
}

private struct FakeServerRequestParams: Decodable, Sendable {
    let paneID: String?
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case title
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

private struct FakeServerResponse<Result: Encodable>: Encodable {
    let id: String
    let result: Result
}

private struct FakeSubscriptionResult: Encodable {
    let type = "subscription_started"
}

private struct FakeServerAction: Sendable {
    let response: Data
    let isSubscription: Bool
}

private enum FakeWindowTitleAction: Equatable, Sendable {
    case set(String)
    case clear
}

private actor FakeHerdrServerState {
    private var panes: [PaneInfo]
    private var focused: [String] = []
    private var windowTitle: String?
    private var titleActions: [FakeWindowTitleAction] = []

    init(panes: [PaneInfo]) {
        self.panes = panes
    }

    func setPanes(_ panes: [PaneInfo]) {
        self.panes = panes
    }

    var focusedPaneIDs: [String] { focused }
    var currentWindowTitle: String? { windowTitle }
    var windowTitleActions: [FakeWindowTitleAction] { titleActions }

    func action(for request: FakeServerRequest) throws -> FakeServerAction {
        let encoder = JSONEncoder()
        let response: Data
        let isSubscription: Bool

        switch request.method {
        case "pane.list":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: PaneListResult(type: "pane_list", panes: panes)
            ))
            isSubscription = false
        case "workspace.list":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: WorkspaceListResult(type: "workspace_list", workspaces: [])
            ))
            isSubscription = false
        case "tab.list":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: TabListResult(type: "tab_list", tabs: [])
            ))
            isSubscription = false
        case "events.subscribe":
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: FakeSubscriptionResult()
            ))
            isSubscription = true
        case "pane.focus":
            guard let paneID = request.params.paneID else {
                throw FakeHerdrServerError.malformedRequest
            }
            guard let pane = panes.first(where: { $0.paneID == paneID }) else {
                throw FakeHerdrServerError.missingPane(paneID)
            }
            focused.append(paneID)
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: PaneFocusResult(type: "pane_info", pane: pane)
            ))
            isSubscription = false
        case "client.window_title.set":
            guard let title = request.params.title else {
                throw FakeHerdrServerError.malformedRequest
            }
            windowTitle = title
            titleActions.append(.set(title))
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: ClientWindowTitleResult(
                    type: "client_window_title",
                    changed: true,
                    reason: "set"
                )
            ))
            isSubscription = false
        case "client.window_title.clear":
            windowTitle = nil
            titleActions.append(.clear)
            response = try encoder.encode(FakeServerResponse(
                id: request.id,
                result: ClientWindowTitleResult(
                    type: "client_window_title",
                    changed: true,
                    reason: "cleared"
                )
            ))
            isSubscription = false
        default:
            throw FakeHerdrServerError.unsupportedMethod(request.method)
        }
        return FakeServerAction(response: response, isSubscription: isSubscription)
    }
}

private final class FakeHerdrServer: @unchecked Sendable {
    let url: URL

    private let state: FakeHerdrServerState
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var listenerFD: Int32
    private var peerFDs: Set<Int32> = []
    private var subscriptionPeerFDs: Set<Int32> = []
    private var stopped = false

    init(url: URL, panes: [PaneInfo]) throws {
        self.url = url
        state = FakeHerdrServerState(panes: panes)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = Darwin.unlink(url.path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FakeHerdrServerError.systemCall("socket", errno)
        }
        listenerFD = fd

        do {
            try Self.bindAndListen(fd: fd, path: url.path)
        } catch {
            Darwin.close(fd)
            _ = Darwin.unlink(url.path)
            throw error
        }

        workers.enter()
        let workers = workers
        Task.detached { [weak self, workers] in
            defer { workers.leave() }
            self?.acceptConnections(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    func setPanes(_ panes: [PaneInfo]) async {
        await state.setPanes(panes)
    }

    func pushAgentStatusEvent(paneID: String, status: AgentStatus) async {
        let event = EventEnvelope(
            event: "pane.agent_status_changed",
            data: EventData(paneID: paneID, workspaceID: nil, agentStatus: status)
        )
        guard let data = try? JSONEncoder().encode(event) else { return }
        let peers = subscriptionPeers
        for peer in peers where !Self.sendLine(data, to: peer) {
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
    }

    var focusedPaneIDs: [String] {
        get async { await state.focusedPaneIDs }
    }

    var currentWindowTitle: String? {
        get async { await state.currentWindowTitle }
    }

    var windowTitleActions: [FakeWindowTitleAction] {
        get async { await state.windowTitleActions }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let listener = listenerFD
        listenerFD = -1
        let peers = Array(peerFDs)
        lock.unlock()

        if listener >= 0 {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        for peer in peers {
            _ = Darwin.shutdown(peer, SHUT_RDWR)
        }
        workers.wait()
        _ = Darwin.unlink(url.path)
    }

    private static func bindAndListen(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw FakeHerdrServerError.socketPathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                _ = Darwin.strlcpy(destination, source, pathCapacity)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.bind(fd, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw FakeHerdrServerError.systemCall("bind", errno)
        }
        guard Darwin.listen(fd, 32) == 0 else {
            throw FakeHerdrServerError.systemCall("listen", errno)
        }
    }

    private func acceptConnections(listenerFD: Int32) {
        while !isStopped {
            let peer = Darwin.accept(listenerFD, nil, nil)
            guard peer >= 0 else {
                if errno == EINTR { continue }
                return
            }
            configure(peer: peer)
            guard register(peer: peer) else {
                Darwin.close(peer)
                return
            }
            workers.enter()
            let workers = workers
            Task.detached { [weak self, workers] in
                defer { workers.leave() }
                guard let self else { return }
                defer {
                    self.close(peer: peer)
                }
                await self.serve(peer: peer)
            }
        }
    }

    private func serve(peer: Int32) async {
        var reader = SocketLineReader()
        while !isStopped {
            switch reader.nextLine(from: peer) {
            case .line(let data):
                do {
                    let request = try JSONDecoder().decode(FakeServerRequest.self, from: data)
                    let action = try await state.action(for: request)
                    guard Self.sendLine(action.response, to: peer) else { return }
                    if action.isSubscription {
                        markSubscription(peer: peer)
                    }
                } catch {
                    return
                }
            case .timedOut:
                continue
            case .closed:
                return
            }
        }
    }

    private func configure(peer: Int32) {
        var enabled: Int32 = 1
        let enabledSize = socklen_t(MemoryLayout.size(ofValue: enabled))
        _ = withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, $0, enabledSize)
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        let timeoutSize = socklen_t(MemoryLayout.size(ofValue: timeout))
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, $0, timeoutSize)
        }
    }

    private static func sendLine(_ data: Data, to peer: Int32) -> Bool {
        var framed = data
        framed.append(0x0A)
        return framed.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(peer, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                if count > 0 {
                    sent += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func register(peer: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        peerFDs.insert(peer)
        return true
    }

    private func markSubscription(peer: Int32) {
        lock.lock()
        subscriptionPeerFDs.insert(peer)
        lock.unlock()
    }

    private var subscriptionPeers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return Array(subscriptionPeerFDs)
    }

    private func close(peer: Int32) {
        lock.lock()
        peerFDs.remove(peer)
        subscriptionPeerFDs.remove(peer)
        lock.unlock()
        Darwin.close(peer)
    }
}

private enum SocketReadResult {
    case line(Data)
    case timedOut
    case closed
}

private struct SocketLineReader {
    private var buffer = Data()

    mutating func nextLine(from fd: Int32) -> SocketReadResult {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return .line(line)
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                return .closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return .timedOut
            } else {
                return .closed
            }
        }
    }
}
