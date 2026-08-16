# Herdr Menubar Multi-Session Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically discover every active Herdr session and aggregate its blocked, completed, and working agents into one status-first menu without allowing one session failure to disturb another.

**Architecture:** `SessionDiscovery` scans Herdr's public default and named socket locations. A `SessionSupervisor` actor reconciles those descriptors and owns one fixed-socket `HerdrClient` per session; `AgentStore` consumes session-qualified events and derives grouped menu state on the main actor.

**Tech Stack:** Swift 6, SwiftUI `MenuBarExtra`, Observation, Network.framework Unix-domain sockets, XCTest, Xcode 26.

**Design spec:** `docs/superpowers/specs/2026-08-15-herdr-menubar-multi-session-design.md`

---

## File map

| Path | Responsibility |
| --- | --- |
| `HerdrMenubar/Herdr/SessionDiscovery.swift` | Session identity, descriptors, configuration-root resolution, shallow socket discovery |
| `HerdrMenubar/Herdr/SessionSupervisor.swift` | Per-session client ownership, reconciliation, grace removal, aggregate event stream, routed commands |
| `HerdrMenubar/Herdr/HerdrClient.swift` | One fixed socket's protocol, subscription, request, refresh, and reconnect state machine |
| `HerdrMenubar/Status/AgentStore.swift` | Main-actor session state, aggregate count, grouped presentation, focus/activation flow |
| `HerdrMenubar/Menu/StatusMenu.swift` | Status-first sections, session subheadings, unavailable-session area, empty states |
| `HerdrMenubar/Menu/MenuBarIcon.swift` | Aggregate connection/attention icon and accessibility text |
| `HerdrMenubar/App/HerdrMenubarApp.swift` | Production composition and ordered startup/shutdown |
| `HerdrMenubarTests/SessionDiscoveryTests.swift` | Real-filesystem discovery coverage |
| `HerdrMenubarTests/SessionSupervisorTests.swift` | Deterministic actor, grace, retry, routing, and stale-event coverage |
| `HerdrMenubarTests/AgentStoreTests.swift` | Composite identity, grouping, aggregate state, routed selection |
| `HerdrMenubarTests/MultiSessionIntegrationTests.swift` | Two simultaneous fake Herdr Unix-socket servers |
| `HerdrMenubarTests/HerdrClientTests.swift` | Fixed-socket client regression coverage |
| `HerdrMenubarTests/MenuBarIconTests.swift` | Aggregate icon modes |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Renamed and newly added source/test files |
| `README.md` | Automatic multi-session behavior and revised discovery contract |

## Shared test command

Use this base command throughout:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

### Task 1: Add automatic session discovery alongside the existing resolver

**Files:**
- Create: `HerdrMenubar/Herdr/SessionDiscovery.swift`
- Create: `HerdrMenubarTests/SessionDiscoveryTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the new source and test files to the Xcode project**

Use these unused IDs consistently:

```text
B10000000000000000000007  SessionDiscovery.swift file reference
B10000000000000000000008  SessionDiscovery.swift build file
B10000000000000000000009  SessionDiscoveryTests.swift file reference
B1000000000000000000000A  SessionDiscoveryTests.swift build file
```

Add the production file under the `Herdr` group and `DC457981E1521EB96966F01E`; add the test file under `HerdrMenubarTests` and `E757C085039C0A48930F6D5E`. Leave the existing resolver and its tests in place until Task 2 changes every client initializer, keeping this commit buildable.

- [ ] **Step 2: Replace the old resolver tests with failing discovery tests**

Write `SessionDiscoveryTests` with a fresh temporary configuration root per test. Bind real Unix sockets with `Darwin.socket`, `sockaddr_un`, `Darwin.bind`, and close/unlink them in `addTeardownBlock`. Cover these exact cases:

```swift
func testDiscoversDefaultAndNamedSocketsInStableOrder() async throws {
    let root = try makeRoot()
    try makeUnixSocket(at: root.appending(path: "herdr.sock"))
    try makeUnixSocket(at: root.appending(path: "sessions/work/herdr.sock"))
    try makeUnixSocket(at: root.appending(path: "sessions/alpha/herdr.sock"))

    XCTAssertEqual(try await SessionDiscovery(configRoot: root).discover(), [
        SessionDescriptor(id: .default, socketURL: root.appending(path: "herdr.sock")),
        SessionDescriptor(id: .named("alpha"), socketURL: root.appending(path: "sessions/alpha/herdr.sock")),
        SessionDescriptor(id: .named("work"), socketURL: root.appending(path: "sessions/work/herdr.sock"))
    ])
}

func testIgnoresFilesMissingSocketsSymlinksAndDeepDescendants() async throws
func testMissingRootIsSuccessfulEmptyDiscovery() async throws
func testAcceptsSpacesUnicodeAndDotPrefixedDirectChildNames() async throws
func testRepeatedScansReturnIdenticalDescriptorsAndOrdering() async throws
func testXDGConfigHomeSelectsConfigurationRoot() throws
func testHerdrSessionAndSocketPathDoNotLimitDiscovery() throws
func testUnreadableSessionsDirectoryThrowsInsteadOfPretendingEmpty() async throws
```

Use short roots such as `/tmp/hm-<8 hex characters>` so nested socket paths remain below macOS's `sockaddr_un.sun_path` limit. For valid-name coverage, create sessions named `client work`, `日本語`, and `.scratch` and assert all three are discovered. Scan the same tree at least three times and assert the complete descriptor arrays are identical. For environment tests, assert `SessionDiscovery.configurationRoot(environment:homeDirectory:)` returns `$XDG_CONFIG_HOME/herdr` when non-empty and `~/.config/herdr` otherwise. Pass `HERDR_SESSION` and `HERDR_SOCKET_PATH` alongside `XDG_CONFIG_HOME` and assert the same root.

- [ ] **Step 3: Run the discovery test target and verify it fails**

Run:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/SessionDiscoveryTests
```

Expected: compilation fails because `SessionID`, `SessionDescriptor`, and `SessionDiscovery` do not exist.

- [ ] **Step 4: Implement session identity and shallow discovery**

Replace `SessionDiscovery.swift` with these public shapes and behavior:

```swift
import Foundation

enum SessionID: Hashable, Sendable {
    case `default`
    case named(String)

    var displayName: String {
        switch self {
        case .default: "Default"
        case .named(let name): name
        }
    }
}

struct SessionDescriptor: Identifiable, Equatable, Sendable {
    let id: SessionID
    let socketURL: URL
    var displayName: String { id.displayName }
}

protocol SessionDiscovering: Sendable {
    func discover() async throws -> [SessionDescriptor]
}

struct SessionDiscovery: SessionDiscovering, @unchecked Sendable {
    let configRoot: URL
    private let fileManager: FileManager

    init(configRoot: URL, fileManager: FileManager = .default) {
        self.configRoot = configRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.init(
            configRoot: Self.configurationRoot(environment: environment, homeDirectory: homeDirectory),
            fileManager: fileManager
        )
    }

    static func configurationRoot(environment: [String: String], homeDirectory: URL) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        return base.appending(path: "herdr", directoryHint: .isDirectory).standardizedFileURL
    }

    func discover() async throws -> [SessionDescriptor] {
        var result: [SessionDescriptor] = []
        let defaultSocket = configRoot.appending(path: "herdr.sock")
        if try fileType(at: defaultSocket) == .typeSocket {
            result.append(SessionDescriptor(id: .default, socketURL: defaultSocket))
        }

        let sessions = configRoot.appending(path: "sessions", directoryHint: .isDirectory)
        guard let sessionsType = try fileType(at: sessions) else { return result }
        guard sessionsType == .typeDirectory else { return result }
        let names = try fileManager.contentsOfDirectory(atPath: sessions.path)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .sorted {
                let lhs = $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let rhs = $1.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        for name in names {
            let directory = sessions.appending(path: name, directoryHint: .isDirectory)
            guard try fileType(at: directory) == .typeDirectory else { continue }
            let socket = directory.appending(path: "herdr.sock")
            guard try fileType(at: socket) == .typeSocket else { continue }
            result.append(SessionDescriptor(id: .named(name), socketURL: socket))
        }
        return result
    }

    private func fileType(at url: URL) throws -> FileAttributeType? {
        do {
            return try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        }
    }
}
```

- [ ] **Step 5: Run discovery tests and the full unit suite**

Expected: `SessionDiscoveryTests` and the existing full unit suite pass because the legacy resolver remains until Task 2.

- [ ] **Step 6: Commit discovery**

```bash
git add HerdrMenubar/Herdr/SessionDiscovery.swift HerdrMenubarTests/SessionDiscoveryTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: discover active herdr sessions"
```

### Task 2: Give each Herdr client one explicit socket and remove the legacy resolver

**Files:**
- Modify: `HerdrMenubar/Herdr/HerdrClient.swift`
- Modify: `HerdrMenubarTests/HerdrClientTests.swift`
- Modify: `HerdrMenubarTests/HerdrClientTestSupport.swift`
- Delete: `HerdrMenubar/Herdr/SocketPathResolver.swift`
- Delete: `HerdrMenubarTests/SocketPathResolverTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add a failing fixed-socket client test**

Extend `FakeHerdrConnectionFactory` to append every `socketURL` passed to `connect(to:)` and expose `var connectedSocketURLs: [URL]`. Add:

```swift
func testUsesConfiguredSocketForSubscriptionSnapshotMetadataAndFocus() async throws {
    let url = URL(fileURLWithPath: "/tmp/session-alpha.sock")
    let factory = FakeHerdrConnectionFactory()
    let client = makeClient(factory: factory, socketURL: url)
    let events = await client.events()
    await client.start()
    _ = await completeBootstrap(factory: factory, discovered: ["pane"], authoritative: ["pane"])
    _ = await events.next()

    let focus = Task { try await client.focus(paneID: "pane") }
    let connection = await factory.connection(at: 5)
    let request = await connection.nextSent()
    await connection.reply(to: request, result: paneFocusResult(id: "pane"))
    _ = try await focus.value

    XCTAssertEqual(Set(await factory.connectedSocketURLs), [url])
    await client.stop()
}
```

- [ ] **Step 2: Run the client test and verify the new initializer is missing**

Expected: compile failure at `socketURL:`.

- [ ] **Step 3: Replace path resolution with a stored URL**

In `HerdrClient`, replace `pathResolver` with:

```swift
private let socketURL: URL

init(
    socketURL: URL,
    connectionFactory: any HerdrConnectionFactory = NWHerdrConnectionFactory(),
    backoff: BackoffPolicy = BackoffPolicy(),
    sleeper: any Sleeper = TaskSleeper(),
    requestTimeout: Duration = .seconds(5),
    subscriptionRebuildDebounce: Duration = .milliseconds(100)
) {
    self.socketURL = socketURL
    self.connectionFactory = connectionFactory
    self.backoff = backoff
    self.sleeper = sleeper
    self.requestTimeout = requestTimeout
    self.subscriptionRebuildDebounce = subscriptionRebuildDebounce
}
```

Delete both local `pathResolver.resolve()` calls. `makeSubscription` and `request` must pass the stored `socketURL` to `connectionFactory.connect(to:)`. Remove `FakePathResolver` and update `makeClient`:

```swift
private func makeClient(
    factory: FakeHerdrConnectionFactory,
    socketURL: URL = URL(fileURLWithPath: "/tmp/fake-herdr.sock"),
    debounce: Duration = .zero
) -> HerdrClient {
    HerdrClient(
        socketURL: socketURL,
        connectionFactory: factory,
        backoff: .immediate,
        sleeper: ImmediateSleeper(),
        subscriptionRebuildDebounce: debounce
    )
}
```

Keep the host app buildable until the coordinated store/menu/app migration by adding this temporary internal initializer:

```swift
init() {
    let root = SessionDiscovery.configurationRoot(
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
    self.init(socketURL: root.appending(path: "herdr.sock"))
}
```

Task 5 removes this initializer when `HerdrMenubarApp` begins constructing `SessionSupervisor`; it is an implementation bridge, not retained compatibility behavior.

- [ ] **Step 4: Run all Herdr client tests**

Expected: all `HerdrClientTests` pass and no `SocketPathResolving` references remain:

```bash
rg 'SocketPathResolving|SocketPathResolver|pathResolver' HerdrMenubar HerdrMenubarTests
```

Expected output: none.

- [ ] **Step 5: Remove legacy files and their project entries, then run the full suite**

Delete `SocketPathResolver.swift` and `SocketPathResolverTests.swift`. Remove their existing build-file entries `12A000000000000000000004` and `12A000000000000000000002`, file references `12A000000000000000000014` and `12A000000000000000000012`, group children, and Sources-phase entries from `project.pbxproj`.

Expected: the full non-UI suite and an ordinary app build pass, and `xcodebuild -list -project HerdrMenubar.xcodeproj` parses the project successfully.

- [ ] **Step 6: Commit the fixed-socket client**

```bash
git add HerdrMenubar/Herdr/HerdrClient.swift HerdrMenubarTests/HerdrClientTests.swift HerdrMenubarTests/HerdrClientTestSupport.swift HerdrMenubar/Herdr/SocketPathResolver.swift HerdrMenubarTests/SocketPathResolverTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "refactor: bind herdr clients to one socket"
```

### Task 3: Add the session supervisor and independent routing

**Files:**
- Create: `HerdrMenubar/Herdr/SessionSupervisor.swift`
- Create: `HerdrMenubarTests/SessionSupervisorTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add project references for the new production and test files**

Use these unused IDs consistently:

```text
B10000000000000000000001  SessionSupervisor.swift file reference
B10000000000000000000002  SessionSupervisor.swift build file
B10000000000000000000003  SessionSupervisorTests.swift file reference
B10000000000000000000004  SessionSupervisorTests.swift build file
```

Add the production file under the `Herdr` group and `DC457981E1521EB96966F01E`; add the test file under `HerdrMenubarTests` and `E757C085039C0A48930F6D5E`.

- [ ] **Step 2: Write failing tests for lifecycle, isolation, and routing**

Create actor fakes with these exact seams:

```swift
actor FakeSessionDiscovery: SessionDiscovering {
    var results: [Result<[SessionDescriptor], Error>]
    func discover() async throws -> [SessionDescriptor]
}

actor FakeSessionClient: SessionClientServing {
    let stream: AsyncStream<HerdrClientEvent>
    func events() -> AsyncStream<HerdrClientEvent>
    func start()
    func stop() async
    func retryNow() async
    func refresh()
    func focus(paneID: String) async throws -> PaneInfo
    func send(_ event: HerdrClientEvent)
}

actor FakeSessionClientFactory: SessionClientCreating {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing
}
```

Tests:

```swift
func testSuccessfulEmptyReconciliationPublishesEmptyDiscoverySnapshot() async
func testCreatesOneClientPerDescriptorAndDoesNotDuplicateOnRepeatedScan() async
func testNewNamedSessionAppearingWhileRunningCreatesAndStartsClient() async
func testForwardsConnectedSnapshotWithOwningDescriptor() async
func testOneClientDisconnectDoesNotChangeTheOtherClient() async
func testFocusAndRefreshRouteOnlyToRequestedSession() async throws
func testUnknownSessionFocusThrowsNamedUnavailableError() async
func testStopCancelsConsumersAndStopsEveryClientOnce() async
func testOverlappingPeriodicScanAndRetryAreSingleFlightAndApplyNewestResult() async
func testStopAwaitsDiscoveryReconciliationConsumersAndSleepers() async
func testStopDuringBlockedClientCreationCleansCreatedClientWithoutStartingIt() async
func testStopResumesRetryWaitingOnBlockedReconciliation() async
```

Use an injected sleeper whose discovery wait can be released manually. Assert the first successful scan always emits `.discoverySnapshot`, including `[]`, before client connection events.

- [ ] **Step 3: Run supervisor tests and verify they fail to compile**

Expected: missing `SessionSupervisor`, events, and client factory protocols.

- [ ] **Step 4: Implement the supervisor API and one-client-per-session runtime**

Define these interfaces in `SessionSupervisor.swift`:

```swift
import Foundation
import OSLog

protocol SessionClientServing: Sendable {
    func events() async -> AsyncStream<HerdrClientEvent>
    func start() async
    func stop() async
    func retryNow() async
    func refresh() async
    func focus(paneID: String) async throws -> PaneInfo
}

extension HerdrClient: SessionClientServing {}

protocol SessionClientCreating: Sendable {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing
}

struct LiveSessionClientFactory: SessionClientCreating {
    func makeClient(for descriptor: SessionDescriptor) async -> any SessionClientServing {
        HerdrClient(socketURL: descriptor.socketURL)
    }
}

enum SessionSupervisorEvent: Equatable, Sendable {
    case discoverySnapshot([SessionDescriptor])
    case connected(SessionDescriptor, PresentationSnapshot)
    case snapshot(SessionID, PresentationSnapshot)
    case unavailable(SessionID, String)
    case removed(SessionID)
}

enum SessionSupervisorError: LocalizedError, Equatable, Sendable {
    case sessionUnavailable(String)
    var errorDescription: String? {
        switch self { case .sessionUnavailable(let name): "\(name) is unavailable" }
    }
}
```

Implement `SessionSupervisor` as an actor with:

```swift
init(
    discovery: any SessionDiscovering,
    clientFactory: any SessionClientCreating,
    sleeper: any Sleeper = TaskSleeper(),
    discoveryInterval: Duration = .seconds(2),
    removalGracePeriod: Duration = .seconds(10)
)

func events() -> AsyncStream<SessionSupervisorEvent>
func start()
func stop() async
func retryUnavailable() async
func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo
func refresh(sessionID: SessionID) async
```

Its `Runtime` stores `descriptor`, existential `client`, `generation`, `isPresent`, `isConnected`, `eventTask`, and optional `graceTask`. `start()` creates one generation-scoped loop that requests reconciliation immediately, sleeps for the injected two-second interval, and repeats.

All scans must go through one coalescing worker owned by the supervisor. Maintain `requestedReconciliationGeneration`, `completedReconciliationGeneration`, one `reconciliationTask`, and generation-keyed waiters returning `ReconciliationOutcome`. Define the outcome as `status: .applied | .failed | .stopped` plus `retriedSessionIDs`. A periodic tick or `retryUnavailable()` increments the requested generation. If no worker exists, start one. The worker captures the latest requested generation, awaits `discovery.discover()`, validates the supervisor lifecycle generation, applies that result, then resumes every waiter from the prior completed generation through the captured generation with the same applied outcome. It marks the captured generation complete and repeats if a newer request arrived while the scan suspended. Thus every coalesced caller receives the exact result that satisfied it, at most one `discover()` call is active, and an older result cannot apply after a newer request. A thrown discovery error logs, resumes the satisfied waiters with `.failed` and no retried IDs, does not publish a snapshot, and leaves prior runtimes intact.

A successful reconciliation publishes `.discoverySnapshot(descriptors)` before adding/removing runtimes. The overlap test must block the first fake discovery call, issue `retryUnavailable()`, assert the fake's maximum concurrent call count remains one, release the first result, then assert the queued second result is the final applied descriptor set.

For a new descriptor, store the runtime before calling `client.start()`, subscribe to `client.events()` first, and forward only when both supervisor lifecycle generation and runtime generation still match. Forward `.connected` and `.snapshot` only while `isPresent`; forward `.disconnected` as `.unavailable` and clear `isConnected` only for that runtime.

Runtime creation must revalidate lifecycle generation and `Task.isCancelled` after each suspension: `clientFactory.makeClient`, `client.events`, and `client.start`. If ownership is lost after factory creation but before insertion, immediately `stop()` that client and return without insertion or start. If ownership is lost after insertion/start, remove the matching runtime, cancel and await its event task, stop the client, and publish no session event. The blocking-factory shutdown test pauses `makeClient`, calls `stop()`, releases the factory, and asserts the resulting client was stopped once, never started, and never inserted.

Route `focus` and `refresh` by `SessionID`. `focus` throws `.sessionUnavailable(descriptor.displayName)` unless the matching runtime exists, is present, and is connected.

`stop()` invalidates the supervisor generation and removes the runtimes first so late events fail ownership checks. Before awaiting tasks, drain every pending reconciliation continuation with `.stopped` and no retried IDs; `retryUnavailable()` returns immediately without retrying clients when it receives `.stopped`. Capture and cancel the discovery loop, reconciliation worker, every grace task, and every client-event task. Stop all clients to unblock their streams, then await every captured task's `.value`. Only after all owned tasks terminate should `stop()` finish aggregate event continuations and return. The shutdown tests use blocking fake discovery, sleepers, streams, and a retry task; they assert every termination flag is set and the retry task returns before awaited `stop()` completes.

- [ ] **Step 5: Run supervisor and client tests**

Expected: supervisor lifecycle/routing tests and existing client tests pass.

- [ ] **Step 6: Commit independent session supervision**

```bash
git add HerdrMenubar/Herdr/SessionSupervisor.swift HerdrMenubarTests/SessionSupervisorTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: supervise independent herdr sessions"
```

### Task 4: Add grace removal, reappearance, and targeted retry

**Files:**
- Modify: `HerdrMenubar/Herdr/SessionSupervisor.swift`
- Modify: `HerdrMenubarTests/SessionSupervisorTests.swift`

- [ ] **Step 1: Add deterministic failing grace-period tests**

Extend the fake sleeper to record requested `Duration` values and release a specific wait. Add:

```swift
func testMissingSocketPublishesUnavailableAndClearsConnectionImmediately() async
func testReappearanceWithinGraceKeepsClientAndRetriesIt() async
func testGraceExpiryStopsClientAwaitsEventConsumerThenPublishesRemoved() async
func testStopDuringGraceCleanupAwaitsInFlightRemoval() async
func testReappearanceDuringBlockedRemovalKeepsNewRuntimeAndSuppressesOldRemovedEvent() async
func testLateEventFromRemovedGenerationIsIgnored() async
func testPresentButDisconnectedSocketIsNotRemoved() async
func testRetryRunsDiscoveryImmediatelyAndRetriesOnlyDisconnectedClients() async
func testCoalescedRetryCallersShareOutcomeAndRetryReappearedClientOnce() async
func testDiscoveryFailureDoesNotPublishEmptySnapshotOrRemoveHealthyRuntime() async
```

Use injected `.seconds(2)` discovery and `.seconds(10)` grace durations. Never sleep wall-clock time in these tests.

- [ ] **Step 2: Run the new tests and verify missing grace behavior**

Expected: missing descriptors are not yet retained/removed according to the grace contract.

- [ ] **Step 3: Implement descriptor presence reconciliation**

On every successful scan:

```swift
let discoveredIDs = Set(descriptors.map(\.id))
publish(.discoverySnapshot(descriptors))

for descriptor in descriptors {
    if var runtime = runtimes[descriptor.id] {
        let returnedDuringGrace = !runtime.isPresent
        runtime.isPresent = true
        runtime.graceTask?.cancel()
        runtime.graceTask = nil
        runtimes[descriptor.id] = runtime
        if returnedDuringGrace { await runtime.client.retryNow() }
    } else {
        await addRuntime(descriptor, supervisorGeneration: generation)
    }
}

for id in runtimes.keys where !discoveredIDs.contains(id) {
    markMissing(id, supervisorGeneration: generation)
}
```

`markMissing` must be idempotent. On the first missing scan it sets `isPresent = false`, `isConnected = false`, publishes `.unavailable(id, "Session socket unavailable")`, and starts one grace task. A runtime whose descriptor remains in discovery is never removed merely because its client is disconnected.

Maintain a supervisor-owned removal registry whose entries contain `sessionID`, the removed runtime's generation, and `Task<Void, Never>`. When grace expires, validate both generations and continued absence, remove the runtime, cancel its event task, and atomically register a removal entry before leaving the actor. That task stops the client to unblock the stream, awaits the canceled event task's `.value`, then calls back into the supervisor with its session ID, runtime generation, and removal token. The callback unregisters that exact entry. It publishes `.removed(id)` only when the lifecycle is still running and `runtimes[id]` does not contain a newer generation; if a replacement runtime exists, the stale removal event is suppressed. `stop()` captures and awaits all registered removal tasks in addition to active-runtime tasks; it does not finish aggregate streams until both sets are empty. Actor serialization must guarantee that a runtime is always owned either by `runtimes` or by the removal registry, never by neither. Reappearance before expiry cancels grace and invokes `retryNow()` once; reappearance after cleanup has begun may create a new generation immediately because stale cleanup cannot remove it from presentation.

The stop-during-cleanup test blocks `FakeSessionClient.stop()`, releases the grace timer so the runtime moves into `removalTasks`, starts supervisor `stop()`, and asserts stop does not return until the fake client stop and event consumer are released and terminated.

The reappearance-during-cleanup test blocks the old client's stop, makes the same descriptor discoverable again, asserts a new runtime generation connects, releases the old cleanup, and verifies no `.removed(id)` follows the replacement `.connected` event.

Have the single-flight reconciliation worker return one `ReconciliationOutcome` to every request generation satisfied by that scan. `retryUnavailable()` requests and awaits its generation's outcome, then snapshots clients with `isConnected == false` whose IDs are not in `outcome.retriedSessionIDs`, and calls `retryNow()` once on each. Connected sessions remain untouched, coalesced callers share the applied result, reappearing sessions are not retried twice, and a retry arriving after a periodic scan has started waits for its queued newer scan rather than using the older result.

- [ ] **Step 4: Run all supervisor tests repeatedly**

Run the supervisor test target three times. Expected: no timing flakes, leaked continuations, duplicate clients, or duplicate removal events.

- [ ] **Step 5: Commit grace handling**

```bash
git add HerdrMenubar/Herdr/SessionSupervisor.swift HerdrMenubarTests/SessionSupervisorTests.swift
git commit -m "feat: reconcile session restarts with grace"
```

### Task 5: Migrate the store, menu, icon, and app composition atomically

**Files:**
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/Menu/StatusMenu.swift`
- Modify: `HerdrMenubar/Menu/MenuBarIcon.swift`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`
- Modify: `HerdrMenubarTests/MenuBarIconTests.swift`

- [ ] **Step 1: Replace single-client tests with failing aggregate-store tests**

Replace `FakeAgentClient` with `FakeSessionSupervisor` conforming to:

```swift
protocol SessionSupervising: Sendable {
    func events() async -> AsyncStream<SessionSupervisorEvent>
    func start() async
    func stop() async
    func retryUnavailable() async
    func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo
    func refresh(sessionID: SessionID) async
}

extension SessionSupervisor: SessionSupervising {}
```

Add tests for:

```swift
func testIdenticalPaneIDsInTwoSessionsProduceDistinctCompositeIDs() async
func testAggregatesAttentionAndGroupsStatusThenSession() async
func testSortsDefaultBeforeNamedSessionsAndRowsWithinSession() async
func testCaseFoldEquivalentSessionNamesUseStableSessionIDTieBreaker() async
func testUnavailableClearsOnlyOwningSessionAndKeepsAggregateConnected() async
func testEmptyDiscoveryAndConnectingStatesAreDistinct() async
func testGraceEntryRemainsUntilRemovedEvent() async
func testSelectionFocusesAndRefreshesOwningSessionOnly() async
func testFocusFailureIncludesSessionDisplayNameAndDoesNotActivate() async
func testRetryDelegatesToUnavailableSessions() async
func testStopCancelsConsumerAndRejectsLateEvents() async
func testStoreSubscribesToSupervisorEventsBeforeStartingIt() async
```

Retain and adapt the existing workspace/tab fallback, multi-tab labeling, terminal-preference-after-focus, terminal-activation-failure, hosted-XCTest synchronization, and post-stop late-event tests. Add icon tests covering `.searching`, `.noSessions`, `.connecting`, and `.connected` before changing production code.

- [ ] **Step 2: Run store tests and verify the old global model fails**

Expected: missing composite IDs, sections, aggregate connection states, and routed commands.

- [ ] **Step 3: Implement session-qualified models**

Use these model shapes:

```swift
enum ConnectionState: Equatable, Sendable {
    case searching
    case noSessions
    case connecting
    case connected
}

struct AgentMenuItemID: Hashable, Sendable {
    let sessionID: SessionID
    let paneID: String
}

struct AgentMenuItem: Identifiable, Equatable, Sendable {
    let sessionID: SessionID
    let sessionName: String
    let paneID: String
    let displayLabel: String
    let agentLabel: String
    let status: AgentStatus
    var id: AgentMenuItemID { AgentMenuItemID(sessionID: sessionID, paneID: paneID) }

    var visibleLabel: String {
        displayLabel == agentLabel ? displayLabel : "\(displayLabel) · \(agentLabel)"
    }

    var secondaryLabel: String { "\(status.rawValue) · \(agentLabel)" }
}

struct SessionMenuSection: Identifiable, Equatable, Sendable {
    let session: SessionDescriptor
    let items: [AgentMenuItem]
    var id: SessionID { session.id }
}

struct UnavailableSession: Identifiable, Equatable, Sendable {
    let session: SessionDescriptor
    let message: String
    var id: SessionID { session.id }
}
```

The store keeps this private state keyed by `SessionID` and exposes `attentionSections`, `workingSections`, `unavailableSessions`, `attentionCount`, and `connectionState`:

```swift
private struct SessionPresentationState {
    var descriptor: SessionDescriptor
    var isConnected = false
    var unavailableMessage: String?
    var attentionItems: [AgentMenuItem] = []
    var workingItems: [AgentMenuItem] = []
}
```

Change the existing `AgentMenuItem` initializer to require `session: SessionDescriptor` before its existing pane/workspace/tab inputs. Set `sessionID` and `sessionName` from that descriptor and preserve the current label fallback, multi-tab detection, and sort helpers verbatim.

Consume events as follows:

```swift
case .discoverySnapshot(let descriptors):
    hasCompletedDiscovery = true
    for descriptor in descriptors where sessions[descriptor.id] == nil {
        sessions[descriptor.id] = SessionPresentationState(descriptor: descriptor)
    }
case .connected(let descriptor, let snapshot):
    var state = sessions[descriptor.id] ?? SessionPresentationState(descriptor: descriptor)
    state.descriptor = descriptor
    state.isConnected = true
    state.unavailableMessage = nil
    (state.attentionItems, state.workingItems) = makeItems(snapshot: snapshot, session: descriptor)
    sessions[descriptor.id] = state
case .snapshot(let id, let snapshot):
    guard var state = sessions[id], state.isConnected else { return }
    (state.attentionItems, state.workingItems) = makeItems(snapshot: snapshot, session: state.descriptor)
    sessions[id] = state
case .unavailable(let id, let message):
    guard var state = sessions[id] else { return }
    state.isConnected = false
    state.unavailableMessage = message
    state.attentionItems = []
    state.workingItems = []
    sessions[id] = state
case .removed(let id):
    sessions.removeValue(forKey: id)
```

Extract the existing workspace/tab join and row filtering into `makeItems(snapshot:session:) -> (attention: [AgentMenuItem], working: [AgentMenuItem])`; pass the descriptor into every row initializer and keep the current fallback and sorting logic.

After each event derive state in this order: `.connected` if any session is connected; `.searching` before the first successful discovery; `.noSessions` if discovery succeeded and the dictionary is empty; otherwise `.connecting`.

Sort session sections with Default first, then case-insensitive POSIX display name. When folded names are equal, compare the exact named-session strings with Swift's stable lexical `<` operator as the `SessionID` tie-breaker; test `Alpha` and `alpha` in reversed input order. Preserve the existing blocked-before-done and label sorting inside each section. `attentionCount` is the flattened current count.

Selection calls `supervisor.focus(sessionID:paneID:)`, then activates the current global terminal preference, then `supervisor.refresh(sessionID:)`. Format failure as `Could not focus pane in <session>: <underlying message>` and skip activation/refresh on focus failure.

- [ ] **Step 4: Implement aggregate icon state and its tests**

Cover `.searching`, `.noSessions`, and `.connecting` as dimmed hollow modes with no count; `.connected` with zero as clear; `.connected` with attention as emphasized. Assert accessibility strings exactly:

```text
Searching for Herdr sessions
No Herdr sessions running
Connecting to Herdr sessions
Connected, no agents need attention
Connected, 1 agent needs attention
Connected, 4 agents need attention
```

Treat every non-`.connected` state as `mode = .disconnected`, hollow light, opacity `0.55`, and hidden count. Return the state-specific accessibility strings above. Preserve existing connected presentation.

- [ ] **Step 5: Render grouped sections in StatusMenu**

Use one top-level section label followed by session subheadings:

```swift
if !store.attentionSections.isEmpty {
    sectionLabel("Needs Attention")
    ForEach(store.attentionSections) { section in
        sessionLabel(section.session.displayName)
        ForEach(section.items) { item in
            AgentRow(item: item) { Task { await store.select(item) } }
        }
    }
    Divider()
}
```

Repeat for `workingSections` with `quieter: true`. Implement `sessionLabel` as uppercase caption-secondary text visually subordinate to the top-level section label.

Render unavailable sessions in a compact **RECONNECTING** area using `session.displayName`; do not show their private socket paths. Show **Retry Unavailable Sessions** only when `unavailableSessions` is non-empty. Implement empty text directly from `connectionState`: searching, no sessions, connecting, or no active agents when connected with both item sections empty.

- [ ] **Step 6: Wire ordered production startup and shutdown**

In the fake supervisor, record `events` and `start`. Assert `AgentStore.start()` produces `["events", "start"]`, proving subscription precedes the first discovery scan. Retain the hosted-XCTest synchronization gate test.

Replace the direct client construction with:

```swift
let discovery = SessionDiscovery()
let supervisor = SessionSupervisor(
    discovery: discovery,
    clientFactory: LiveSessionClientFactory()
)
let preferences = Preferences()
_store = State(initialValue: AgentStore(
    supervisor: supervisor,
    terminalActivator: TerminalActivationService(),
    preferences: preferences
))
```

Delete the temporary zero-argument `HerdrClient` initializer from Task 2. Keep the app delegate's terminate-later flow, but make `AgentStore.stop()` cancel and await its aggregate event task before awaiting `supervisor.stop()`. Ensure `start()` obtains the supervisor stream, installs its task, and only then calls `supervisor.start()`.

- [ ] **Step 7: Run all affected tests, the entire suite, and an ordinary build**

Run `AgentStoreTests` and `MenuBarIconTests` first, then the shared full-suite command and an ordinary build. Expected: all tests pass and the app builds with no zero-argument `HerdrClient`, legacy resolver, flattened single-session menu, or non-exhaustive connection-state references.

- [ ] **Step 8: Commit the atomic presentation/composition migration**

```bash
git add HerdrMenubar/Status/AgentStore.swift HerdrMenubar/Menu/StatusMenu.swift HerdrMenubar/Menu/MenuBarIcon.swift HerdrMenubar/App/HerdrMenubarApp.swift HerdrMenubar/Herdr/HerdrClient.swift HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/MenuBarIconTests.swift
git commit -m "feat: present agents across herdr sessions"
```

### Task 6: Prove behavior against two real Unix-socket servers

**Files:**
- Create: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the integration test file to the test target**

Use file reference `B10000000000000000000005` and build file `B10000000000000000000006`; add them to the test group and test Sources phase.

- [ ] **Step 2: Implement a protocol-aware fake Herdr server**

Inside the test file, create `FakeHerdrServer: @unchecked Sendable` around an AF_UNIX listener. It must accept concurrent connections until stopped, parse newline-delimited request JSON, and reply to:

```text
pane.list         -> pane_list using actor-owned panes
workspace.list    -> empty workspace_list
tab.list          -> empty tab_list
events.subscribe  -> subscription_started, then hold the peer for pushed events
pane.focus        -> pane_info and record the focused pane ID
```

Expose `url`, `setPanes(_:)`, `pushAgentStatusEvent()`, `focusedPaneIDs`, and `stop()`. Give every accepted peer a bounded read timeout and close/unlink deterministically in teardown.

`makeTemporaryHerdrRoot()` must create a short `/tmp/hm-<8 hex characters>` directory rather than using the longer per-user temporary directory, keeping `sessions/<name>/herdr.sock` safely below the `sockaddr_un.sun_path` limit.

- [ ] **Step 3: Write the two-server integration test**

```swift
func testTwoServersBootstrapUpdateAndFocusIndependently() async throws {
    let root = try makeTemporaryHerdrRoot()
    let defaultURL = root.appending(path: "herdr.sock")
    let namedURL = root.appending(path: "sessions/work/herdr.sock")
    let defaultServer = try FakeHerdrServer(
        url: defaultURL,
        panes: [pane("duplicate", .done)]
    )
    let namedServer = try FakeHerdrServer(
        url: namedURL,
        panes: [pane("duplicate", .working)]
    )
    defer { defaultServer.stop(); namedServer.stop() }

    let supervisor = SessionSupervisor(
        discovery: SessionDiscovery(configRoot: root),
        clientFactory: IntegrationClientFactory(),
        discoveryInterval: .seconds(30)
    )
    let activator = IntegrationRecordingActivator()
    let store = await MainActor.run {
        AgentStore(supervisor: supervisor, terminalActivator: activator)
    }
    await store.start()

    await eventually { await MainActor.run { store.attentionCount == 1 && store.workingSections.count == 1 } }
    let initialIDs = await MainActor.run {
        (store.attentionSections.flatMap(\.items) + store.workingSections.flatMap(\.items)).map(\.id)
    }
    XCTAssertEqual(Set(initialIDs), [
        AgentMenuItemID(sessionID: .default, paneID: "duplicate"),
        AgentMenuItemID(sessionID: .named("work"), paneID: "duplicate")
    ])

    namedServer.setPanes([pane("duplicate", .blocked)])
    namedServer.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
    await eventually { await MainActor.run { store.attentionCount == 2 } }

    let namedItem = await MainActor.run {
        store.attentionSections.first { $0.id == .named("work") }!.items[0]
    }
    await store.select(namedItem)
    XCTAssertEqual(namedServer.focusedPaneIDs, ["duplicate"])
    XCTAssertEqual(defaultServer.focusedPaneIDs, [])
    await store.stop()
}

func testStoppingOneServerKeepsOtherConnectedAndRestartWithinGraceDoesNotDuplicate() async throws {
    let root = try makeTemporaryHerdrRoot()
    let defaultServer = try FakeHerdrServer(url: root.appending(path: "herdr.sock"), panes: [pane("a", .done)])
    var namedServer: FakeHerdrServer? = try FakeHerdrServer(
        url: root.appending(path: "sessions/work/herdr.sock"),
        panes: [pane("b", .done)]
    )
    defer { defaultServer.stop(); namedServer?.stop() }
    let supervisor = SessionSupervisor(
        discovery: SessionDiscovery(configRoot: root),
        clientFactory: IntegrationClientFactory(),
        discoveryInterval: .seconds(30),
        removalGracePeriod: .seconds(10)
    )
    let store = await MainActor.run {
        AgentStore(supervisor: supervisor, terminalActivator: IntegrationRecordingActivator())
    }
    await store.start()
    await eventually { await MainActor.run { store.attentionCount == 2 } }

    namedServer?.stop()
    namedServer = nil
    await store.retry()
    await eventually {
        await MainActor.run {
            store.attentionCount == 1 && store.unavailableSessions.map(\.id) == [.named("work")]
        }
    }
    XCTAssertEqual(await MainActor.run { store.connectionState }, .connected)

    namedServer = try FakeHerdrServer(
        url: root.appending(path: "sessions/work/herdr.sock"),
        panes: [pane("b", .done)]
    )
    await store.retry()
    await eventually {
        await MainActor.run {
            store.attentionCount == 2 && store.attentionSections.filter { $0.id == .named("work") }.count == 1
        }
    }
    await store.stop()
}
```

Use `eventually` helpers with a one-second deadline for observable state, but inject a controllable grace sleeper so the test never waits ten seconds.

- [ ] **Step 4: Run integration tests five times**

Expected: both tests pass repeatedly with no socket leaks or order dependence.

- [ ] **Step 5: Commit multi-server coverage**

```bash
git add HerdrMenubarTests/MultiSessionIntegrationTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "test: cover simultaneous herdr sessions"
```

### Task 7: Update documentation and perform final validation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite connection discovery documentation**

Document automatic monitoring of:

```text
~/.config/herdr/herdr.sock
~/.config/herdr/sessions/<name>/herdr.sock
$XDG_CONFIG_HOME/herdr/herdr.sock
$XDG_CONFIG_HOME/herdr/sessions/<name>/herdr.sock
```

Remove claims that `HERDR_SOCKET_PATH` or `HERDR_SESSION` select the app's socket. Describe two-second discovery, ten-second removal grace, aggregate badge, status-first/session-second grouping, partial failure isolation, and targeted Retry. Keep notifications and session-selection controls out of the feature list.

State explicitly that a non-empty `XDG_CONFIG_HOME` replaces `~/.config` as the one discovery base; the two roots are not scanned together. Preserve the README guarantees that Herdr remains the source of truth and that pane, agent, session, and acknowledgement state are not persisted.

- [ ] **Step 2: Run complete automated validation**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Release -destination 'platform=macOS'
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
git diff --check
```

Expected: all tests pass, build and analysis succeed, and diff check is silent.

- [ ] **Step 3: Run the installer and ordinary-app smoke check**

Run `./scripts/install.sh`, record the launched PID, and complete the smoke check within a bounded 60-second observation window. Use a default and named Herdr session to verify:

```text
[ ] both sessions appear without relaunching the menu app
[ ] status-first sections contain Default then named session groups
[ ] badge equals blocked + done across both sessions
[ ] selecting duplicate pane IDs focuses only the owning session
[ ] stopping one session clears only its rows and shows reconnecting
[ ] restarting within ten seconds restores it without duplication
[ ] leaving it stopped removes it after grace
[ ] a present session before bootstrap completes shows Connecting to Herdr sessions…
[ ] connected sessions with only idle agents show No active agents
[ ] zero sessions shows No Herdr sessions running and a dim icon
[ ] Retry Unavailable Sessions does not disturb the healthy session
[ ] Quit stops the recorded ordinary-app process within five seconds
```

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
git commit -m "docs: explain multi-session monitoring"
```

## Plan self-review checklist

- [ ] Every design-spec goal maps to Tasks 1–7.
- [ ] Automatic discovery and removal of environment selection map to Tasks 1 and 7.
- [ ] One fixed client per session and independent failure map to Tasks 2–4.
- [ ] Empty authoritative discovery and grace retention map to Tasks 3–5.
- [ ] Composite identity, aggregate count, grouping, routed focus, and startup/shutdown ordering map to Task 5.
- [ ] Two real socket servers map to Task 6.
- [ ] Full tests, Release build, analysis, install, and manual behavior map to Task 7.
- [ ] No notifications, session picker, per-session terminal setting, persistence, or API changes are introduced.
