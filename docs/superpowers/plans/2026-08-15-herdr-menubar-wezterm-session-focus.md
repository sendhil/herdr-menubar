# Herdr Menubar WezTerm Session Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an agent-row click focus the pane inside its owning Herdr session and select that session's existing attached WezTerm tab without spawning a new client.

**Architecture:** Extend each fixed-socket `HerdrClient` with Herdr's public client-window-title requests and route them through `SessionSupervisor`. An on-demand `WezTermFocusAdapter` uses a unique temporary title to correlate the session's foreground attached client with `wezterm cli list`, clears the marker, and activates the exact WezTerm pane through a bounded subprocess runner. `AgentStore` serializes row selections so the latest click wins while cleanup and the owning-session refresh finish before a successor starts.

**Tech Stack:** Swift 6, Swift concurrency actors and `Task`, Foundation `Process`/`Pipe`, AppKit `NSWorkspace`, Herdr newline-delimited JSON over AF_UNIX, WezTerm CLI JSON, XCTest, Xcode 26/macOS 26.

**Design spec:** `docs/superpowers/specs/2026-08-15-herdr-menubar-wezterm-session-focus-design.md`

---

## File map

| File | Responsibility |
| --- | --- |
| `HerdrMenubar/Herdr/APIModels.swift` | Wire models for `client.window_title.set` and `.clear` |
| `HerdrMenubar/Herdr/HerdrClient.swift` | Send bounded title requests through one session's fixed socket |
| `HerdrMenubar/Herdr/SessionSupervisor.swift` | Route title commands to the selected session runtime |
| `HerdrMenubar/System/BoundedProcessRunner.swift` | Launch one direct executable with hard time/output/cancellation ownership |
| `HerdrMenubar/System/WezTermCLI.swift` | Resolve `Contents/MacOS/wezterm`, decode pane JSON, activate an exact pane |
| `HerdrMenubar/System/WezTermFocusAdapter.swift` | Own the temporary-title handshake, lookup, cleanup, pending cleanup, and typed errors |
| `HerdrMenubar/Status/AgentStore.swift` | Serialize latest-wins selections and orchestrate pane focus, WezTerm focus, app activation, refresh |
| `HerdrMenubar/App/HerdrMenubarApp.swift` | Compose the live runner, CLI, adapter, supervisor, and store |
| `HerdrMenubarTests/APIModelsTests.swift` | Prove exact Herdr title request/response wire shapes |
| `HerdrMenubarTests/HerdrClientTests.swift` | Prove title requests use the configured session socket and preserve API-error isolation |
| `HerdrMenubarTests/SessionSupervisorTests.swift` | Prove title set/clear route to only the requested connected session |
| `HerdrMenubarTests/BoundedProcessRunnerTests.swift` | Prove timeout, cancellation, output caps, forced kill, concurrent drain, and reaping |
| `HerdrMenubarTests/WezTermCLITests.swift` | Prove executable resolution, JSON decoding, and exact CLI arguments |
| `HerdrMenubarTests/WezTermFocusAdapterTests.swift` | Prove title handshake, exact matching, cleanup, pending lifecycle, and failures |
| `HerdrMenubarTests/AgentStoreTests.swift` | Prove selection ordering, partial errors, refresh policy, supersession, and stop ownership |
| `HerdrMenubarTests/MultiSessionIntegrationTests.swift` | Prove duplicate pane IDs focus distinct socket sessions and distinct WezTerm panes |
| `HerdrMenubarTests/WezTermSubprocessIntegrationTests.swift` | Exercise the live CLI runner against a temporary fake WezTerm app bundle |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Add the new production and test source files to the correct targets |
| `README.md` | Explain exact existing-tab focus for WezTerm and generic activation elsewhere |

Use these currently unused Xcode project IDs consistently:

```text
C10000000000000000000001  BoundedProcessRunner.swift file reference
C10000000000000000000002  BoundedProcessRunner.swift build file
C10000000000000000000003  WezTermCLI.swift file reference
C10000000000000000000004  WezTermCLI.swift build file
C10000000000000000000005  WezTermFocusAdapter.swift file reference
C10000000000000000000006  WezTermFocusAdapter.swift build file
C10000000000000000000007  BoundedProcessRunnerTests.swift file reference
C10000000000000000000008  BoundedProcessRunnerTests.swift build file
C10000000000000000000009  WezTermCLITests.swift file reference
C1000000000000000000000A  WezTermCLITests.swift build file
C1000000000000000000000B  WezTermFocusAdapterTests.swift file reference
C1000000000000000000000C  WezTermFocusAdapterTests.swift build file
C1000000000000000000000D  WezTermSubprocessIntegrationTests.swift file reference
C1000000000000000000000E  WezTermSubprocessIntegrationTests.swift build file
```

Add production files under the existing `System` group and production Sources phase `DC457981E1521EB96966F01E`. Add test files under `HerdrMenubarTests` and test Sources phase `E757C085039C0A48930F6D5E`.

## Shared test commands

Run focused tests with:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/<TestClass>
```

Run the complete non-UI suite with:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

Xcode's DerivedData and test services require running these commands outside the filesystem sandbox in this workspace. Preserve genuine RED output before adding each production implementation.

---

### Task 1: Add Herdr client-window-title wire support

**Files:**
- Modify: `HerdrMenubar/Herdr/APIModels.swift:70-196`
- Modify: `HerdrMenubar/Herdr/HerdrClient.swift:159-181`
- Modify: `HerdrMenubarTests/APIModelsTests.swift:71-111`
- Modify: `HerdrMenubarTests/HerdrClientTests.swift:1-45`

- [ ] **Step 1: Write failing API model tests**

Extend `APIModelsTests` with exact set/clear request encoding and every current result reason:

```swift
func testClientWindowTitleRequestsEncodeExactWireShapes() throws {
    let set = HerdrRequest(
        id: "title-set",
        method: "client.window_title.set",
        params: ClientWindowTitleSetParams(title: "herdr-menubar-focus:token")
    )
    let clear = HerdrRequest(
        id: "title-clear",
        method: "client.window_title.clear",
        params: EmptyParams()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    XCTAssertEqual(
        String(decoding: try encoder.encode(set), as: UTF8.self),
        #"{"id":"title-set","method":"client.window_title.set","params":{"title":"herdr-menubar-focus:token"}}"#
    )
    XCTAssertEqual(
        String(decoding: try encoder.encode(clear), as: UTF8.self),
        #"{"id":"title-clear","method":"client.window_title.clear","params":{}}"#
    )
}

func testClientWindowTitleResultDecodesSetClearedAndNoForegroundClient() throws {
    for (reason, changed) in [("set", true), ("cleared", true), ("no_foreground_client", false)] {
        let data = Data(#"{"id":"1","result":{"type":"client_window_title","changed":\#(changed),"reason":"\#(reason)"}}"#.utf8)
        let response = try JSONDecoder().decode(
            HerdrResponse<ClientWindowTitleResult>.self,
            from: data
        )
        XCTAssertEqual(response.result, ClientWindowTitleResult(
            type: "client_window_title", changed: changed, reason: reason
        ))
    }
}
```

- [ ] **Step 2: Run API model tests and record RED**

Run the focused `APIModelsTests` command.

Expected: compilation fails because `ClientWindowTitleSetParams` and `ClientWindowTitleResult` do not exist.

- [ ] **Step 3: Add the minimal public wire models**

Add to `APIModels.swift` beside the existing result and params types:

```swift
struct ClientWindowTitleResult: Codable, Equatable, Sendable {
    let type: String
    let changed: Bool
    let reason: String

    var hasForegroundClient: Bool { reason != "no_foreground_client" }
}

struct ClientWindowTitleSetParams: Codable, Equatable, Sendable {
    let title: String
}
```

Keep `reason` as a string so a future server reason decodes without turning a title request into malformed JSON. The adapter interprets only `no_foreground_client`, `set`, and `cleared`.

- [ ] **Step 4: Write failing fixed-socket client tests**

Add tests that call title operations without starting a reconnect loop, inspect the fake connection's exact request, reply with a result, and confirm both calls use only the configured URL:

```swift
func testClientWindowTitleSetAndClearUseConfiguredSocket() async throws {
    let url = URL(fileURLWithPath: "/tmp/title-session.sock")
    let factory = FakeHerdrConnectionFactory()
    let client = makeClient(factory: factory, socketURL: url)

    let setTask = Task { try await client.setClientWindowTitle("marker") }
    let setConnection = await factory.connection(at: 0)
    let setRequest = await setConnection.nextSent()
    XCTAssertEqual(setRequest.method, "client.window_title.set")
    XCTAssertEqual(try setRequest.paramsObject(), ["title": "marker"] as NSDictionary)
    await setConnection.reply(
        to: setRequest,
        result: #"{"type":"client_window_title","changed":true,"reason":"set"}"#
    )
    let setResult = try await setTask.value
    XCTAssertEqual(setResult.reason, "set")

    let clearTask = Task { try await client.clearClientWindowTitle() }
    let clearConnection = await factory.connection(at: 1)
    let clearRequest = await clearConnection.nextSent()
    XCTAssertEqual(clearRequest.method, "client.window_title.clear")
    XCTAssertEqual(try clearRequest.paramsObject(), [:] as NSDictionary)
    await clearConnection.reply(
        to: clearRequest,
        result: #"{"type":"client_window_title","changed":true,"reason":"cleared"}"#
    )
    let clearResult = try await clearTask.value
    XCTAssertEqual(clearResult.reason, "cleared")
    let connectedSocketURLs = await factory.connectedSocketURLs
    XCTAssertEqual(connectedSocketURLs, [url, url])
}

func testClientWindowTitleMethodNotFoundRemainsAnAPIError() async {
    let factory = FakeHerdrConnectionFactory()
    let client = makeClient(factory: factory)
    let task = Task { try await client.setClientWindowTitle("marker") }
    let connection = await factory.connection(at: 0)
    let request = await connection.nextSent()
    await connection.push(
        #"{"id":"\#(request.id)","error":{"code":"method_not_found","message":"unknown method"}}"#
    )

    do {
        _ = try await task.value
        XCTFail("Expected method_not_found")
    } catch let error as HerdrAPIError {
        XCTAssertEqual(
            error,
            HerdrAPIError(code: "method_not_found", message: "unknown method")
        )
    }
}
```

- [ ] **Step 5: Run the two new client tests and record RED**

Expected: compilation fails because `HerdrClient` has no title methods.

- [ ] **Step 6: Implement the two fixed-socket client requests**

Add these actor methods beside `focus(paneID:)`:

```swift
func setClientWindowTitle(_ title: String) async throws -> ClientWindowTitleResult {
    try await clientWindowTitleRequest(
        method: "client.window_title.set",
        params: ClientWindowTitleSetParams(title: title)
    )
}

func clearClientWindowTitle() async throws -> ClientWindowTitleResult {
    try await clientWindowTitleRequest(
        method: "client.window_title.clear",
        params: EmptyParams()
    )
}

private func clientWindowTitleRequest<Params: Encodable & Sendable>(
    method: String,
    params: Params
) async throws -> ClientWindowTitleResult {
    let generation = lifecycleGeneration
    do {
        let result: ClientWindowTitleResult = try await request(
            method: method,
            params: params,
            as: ClientWindowTitleResult.self
        )
        guard result.type == "client_window_title" else {
            throw HerdrClientError.unexpectedResponseType(
                expected: "client_window_title",
                actual: result.type
            )
        }
        return result
    } catch {
        if generation == lifecycleGeneration, shouldInvalidate(for: error) {
            await invalidate(reason: description(for: error), generation: generation)
        }
        throw error
    }
}
```

This preserves the existing rule: transport/protocol failures invalidate only this client, while a Herdr API error such as `method_not_found` stays command-scoped.

- [ ] **Step 7: Run model, client, and full tests**

Run `APIModelsTests`, the full `HerdrClientTests`, then the complete non-UI suite.

Expected: all pass with the baseline suite count plus the four new tests.

- [ ] **Step 8: Commit title wire support**

```bash
git add HerdrMenubar/Herdr/APIModels.swift \
  HerdrMenubar/Herdr/HerdrClient.swift \
  HerdrMenubarTests/APIModelsTests.swift \
  HerdrMenubarTests/HerdrClientTests.swift
git commit -m "feat: control herdr client window titles"
```

---

### Task 2: Route title commands through the owning session

**Files:**
- Modify: `HerdrMenubar/Herdr/SessionSupervisor.swift:4-44,235-245`
- Modify: `HerdrMenubarTests/SessionSupervisorTests.swift:80-155,900-1010`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift:495-575`

- [ ] **Step 1: Extend fake clients and write failing routing tests**

Add title request recording to `FakeSessionClient`:

```swift
private(set) var setWindowTitles: [String] = []
private(set) var clearWindowTitleCount = 0
var setWindowTitleResult = ClientWindowTitleResult(
    type: "client_window_title", changed: true, reason: "set"
)
var clearWindowTitleResult = ClientWindowTitleResult(
    type: "client_window_title", changed: true, reason: "cleared"
)

func setClientWindowTitle(_ title: String) -> ClientWindowTitleResult {
    setWindowTitles.append(title)
    return setWindowTitleResult
}

func clearClientWindowTitle() -> ClientWindowTitleResult {
    clearWindowTitleCount += 1
    return clearWindowTitleResult
}
```

Add supervisor tests:

```swift
func testClientWindowTitleCommandsRouteOnlyToRequestedSession() async throws
func testClientWindowTitleReportsNoForegroundClientFromOwningRuntime() async throws
func testClientWindowTitleCommandsRejectUnknownOrDisconnectedSession() async
```

In the routing test, connect default and named fake clients, call set and clear only for `.named("work")`, and assert the default client's counters remain zero. In the no-client test, configure the named fake result with `changed: false, reason: "no_foreground_client"` and assert the result passes through unchanged. For unavailable cases, assert `SessionSupervisorError.sessionUnavailable(displayName)` exactly.

- [ ] **Step 2: Run supervisor tests and record RED**

Expected: `SessionClientServing`, `SessionSupervising`, and `SessionSupervisor` lack the title methods.

- [ ] **Step 3: Extend the session-qualified interfaces**

Add the unqualified client methods to `SessionClientServing`:

```swift
func setClientWindowTitle(_ title: String) async throws -> ClientWindowTitleResult
func clearClientWindowTitle() async throws -> ClientWindowTitleResult
```

Add the session-qualified methods to `SessionSupervising`:

```swift
func setClientWindowTitle(
    sessionID: SessionID,
    title: String
) async throws -> ClientWindowTitleResult
func clearClientWindowTitle(
    sessionID: SessionID
) async throws -> ClientWindowTitleResult
```

Do not add the unqualified overloads to `SessionSupervising`.

- [ ] **Step 4: Implement runtime validation and routing**

Add one helper and the two commands to the supervisor actor:

```swift
private func commandClient(
    sessionID: SessionID
) throws -> any SessionClientServing {
    guard let runtime = runtimes[sessionID],
          runtime.isPresent,
          runtime.isConnected else {
        throw SessionSupervisorError.sessionUnavailable(sessionID.displayName)
    }
    return runtime.client
}

func setClientWindowTitle(
    sessionID: SessionID,
    title: String
) async throws -> ClientWindowTitleResult {
    try await commandClient(sessionID: sessionID).setClientWindowTitle(title)
}

func clearClientWindowTitle(
    sessionID: SessionID
) async throws -> ClientWindowTitleResult {
    try await commandClient(sessionID: sessionID).clearClientWindowTitle()
}
```

Refactor `focus(sessionID:paneID:)` to use the same helper. Leave `refresh`'s present-only rule unchanged.

- [ ] **Step 5: Update every protocol fake to compile**

Update `FakeSessionSupervisor` in `AgentStoreTests` with actor-isolated title result queues and counters. Its default set/clear results must be successful, and tests must be able to inject `no_foreground_client` or `method_not_found` later without changing production seams.

- [ ] **Step 6: Run supervisor tests three times and the full suite**

Expected: title routing, existing lifecycle stress tests, and the full suite pass without changing discovery, retry, removal, or focus isolation.

- [ ] **Step 7: Commit supervisor routing**

```bash
git add HerdrMenubar/Herdr/SessionSupervisor.swift \
  HerdrMenubarTests/SessionSupervisorTests.swift \
  HerdrMenubarTests/AgentStoreTests.swift
git commit -m "feat: route attached-client titles by session"
```

---

### Task 3: Build a bounded, cancellation-owned subprocess runner

**Files:**
- Create: `HerdrMenubar/System/BoundedProcessRunner.swift`
- Create: `HerdrMenubarTests/BoundedProcessRunnerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add project references for the runner and its tests**

Use project IDs `C100...001`, `C100...002`, `C100...007`, and `C100...008` from the file map. Add the files to the System/test groups and production/test Sources phases before the files exist so the first focused build proves the missing component.

- [ ] **Step 2: Write the runner contract and failing tests**

Create tests for these exact cases:

```swift
func testCapturesStdoutStderrAndExitStatusConcurrently() async throws
func testNonzeroExitReturnsCapturedResultForCallerClassification() async throws
func testStdoutLimitTerminatesAndReapsProcess() async
func testStderrLimitTerminatesAndReapsProcess() async
func testSimultaneousStdoutAndStderrOverflowTerminatesExactlyOnce() async
func testDeadlineTerminatesAndReapsProcess() async
func testCancellationTerminatesAndReapsProcess() async
func testChildIgnoringTerminateIsKilledAfterGraceAndReaped() async
```

The first two can execute `/bin/sh -c` fixtures that write known bytes. Overflow fixtures continuously write to both descriptors. The ignore-terminate fixture must use a temporary executable shell script containing:

```sh
#!/bin/sh
trap '' TERM
while :; do :; done
```

Keep this CPU-bound fixture alive only until the 100-millisecond forced-kill grace expires. Record its PID through the runner's injected launch observer and assert `kill(pid, 0)` eventually returns `-1` with `errno == ESRCH` after the runner returns. Tests create executable fixtures with `FileManager`, `Data.write`, and `chmod`, then remove their temporary directory in teardown.

Import `Darwin` in this test file for `chmod`, `kill`, `SIGKILL`, `errno`, and `ESRCH`.

- [ ] **Step 3: Run focused tests and record RED**

Expected: compilation fails because `BoundedProcessRunner`, `ProcessInvocation`, and `ProcessResult` do not exist.

- [ ] **Step 4: Implement the explicit runner API**

Define:

```swift
struct ProcessInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let deadline: Duration
    let stdoutLimit: Int
    let stderrLimit: Int
}

struct ProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitStatus: Int32
}

enum BoundedProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case stdoutLimitExceeded
    case stderrLimitExceeded
    case cancelled
}

protocol BoundedProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}
```

Give `BoundedProcessRunner` this initializer so process-liveness tests observe the launched PID without exposing mutable production state:

```swift
init(launchObserver: @escaping @Sendable (Int32) -> Void = { _ in })
```

The runner must use an actor-owned execution record containing the `Process`, both read handles, one termination continuation, and an exact execution token. Implement this ownership algorithm:

1. Configure executable URL, arguments, stdout pipe, and stderr pipe without a shell.
2. Install the termination handler before `run()` and resume its continuation exactly once.
3. Launch; invoke the optional test launch observer with the PID.
4. Start one child task per pipe. Each repeatedly reads chunks, appends only while within its independent limit, and throws the corresponding overflow error before unbounded allocation.
5. Race process exit against the invocation deadline and parent cancellation.
6. On timeout, cancellation, reader failure, or overflow, claim the execution token once, call `terminate()`, wait 100 milliseconds, send `kill(pid, SIGKILL)` if still running, and await termination.
7. Close both read handles, await both readers, clear handlers, and return only after the child is reaped and all owned tasks terminate.
8. If stdout and stderr fail concurrently, retain the first actor-claimed terminal error and make every other cleanup path idempotent.

Do not use `Task.detached` without awaiting it. Never reuse environment variables, invoke `/bin/sh`, or interpolate arguments in production.

- [ ] **Step 5: Run runner tests repeatedly**

Run `BoundedProcessRunnerTests` ten times.

Expected: all executions pass, no fixture PID remains alive, and no test exceeds two seconds.

- [ ] **Step 6: Run Thread Sanitizer for the runner target**

Run the focused class once with `-enableThreadSanitizer YES`.

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -enableThreadSanitizer YES \
  -only-testing:HerdrMenubarTests/BoundedProcessRunnerTests
```

Expected: no data race, double continuation resume, or file-handle race report.

- [ ] **Step 7: Commit bounded process ownership**

```bash
git add HerdrMenubar/System/BoundedProcessRunner.swift \
  HerdrMenubarTests/BoundedProcessRunnerTests.swift \
  HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: run bounded terminal subprocesses"
```

---

### Task 4: Add exact WezTerm CLI discovery and pane activation

**Files:**
- Create: `HerdrMenubar/System/WezTermCLI.swift`
- Create: `HerdrMenubarTests/WezTermCLITests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add project references and failing CLI tests**

Use project IDs `C100...003`, `C100...004`, `C100...009`, and `C100...00A`.

Write:

```swift
func testListResolvesSiblingCLIAndDecodesPaneIdentity() async throws
func testActivatePaneUsesExactIntegerPaneIDAndOneSecondDeadline() async throws
func testMissingApplicationThrowsUnavailableWithoutRunningProcess() async
func testMissingSiblingCLIThrowsUnavailableWithoutPATHFallback() async
func testBundleEntryPointWeztermGUIIsNeverExecuted() async
func testNonExecutableSiblingCLIThrowsUnavailable() async
func testListNonzeroExitThrowsControlFailureWithoutExposingStderr() async
func testMalformedUTF8AndJSONThrowMalformedOutput() async
func testListUsesFiveHundredMillisecondDeadlineAndIndependent256KiBLimits() async throws
```

Use a `FakeBoundedProcessRunner` actor that records `ProcessInvocation` values and returns queued results. Use a temporary app-bundle directory for executable validation; create `Contents/MacOS/wezterm` as a regular executable and also create a sentinel `wezterm-gui` that must never appear in invocations.

- [ ] **Step 2: Run CLI tests and record RED**

Expected: missing `WezTermCLIControlling`, `WezTermPane`, and `LiveWezTermCLI`.

- [ ] **Step 3: Implement the CLI-facing types**

Create:

```swift
struct WezTermPane: Decodable, Equatable, Sendable {
    let windowID: Int
    let tabID: Int
    let paneID: Int
    let title: String

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case title
    }
}

enum WezTermCLIError: Error, Equatable, Sendable {
    case unavailable
    case controlFailed
    case malformedOutput
}

enum WezTermCLIConstants {
    static let bundleIdentifier = "com.github.wez.wezterm"
}

@MainActor
protocol WezTermCLIControlling: Sendable {
    func listPanes() async throws -> [WezTermPane]
    func activatePane(id: Int) async throws
}
```

Implement `LiveWezTermCLI` with injected `BoundedProcessRunning`, `FileManager`, and bundle resolver. The production resolver is:

```swift
{ NSWorkspace.shared.urlForApplication(
    withBundleIdentifier: WezTermCLIConstants.bundleIdentifier
) }
```

Resolve only:

```swift
appURL.appending(path: "Contents/MacOS/wezterm")
```

Validate `.typeRegular` and `FileManager.isExecutableFile(atPath:)`. Never use the bundle's `wezterm-gui`, `command -v`, `$PATH`, `/opt/homebrew`, or a shell.

- [ ] **Step 4: Implement exact list and activation invocations**

Use:

```swift
ProcessInvocation(
    executableURL: executable,
    arguments: ["cli", "list", "--format", "json"],
    deadline: .milliseconds(500),
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024
)
```

Decode stdout with `JSONDecoder` directly from `Data`. Treat a nonzero status, any stderr content on failure, and runner launch failure as typed control/unavailable errors without incorporating raw bytes into the localized error or logs.

Activation uses:

```swift
ProcessInvocation(
    executableURL: executable,
    arguments: ["cli", "activate-pane", "--pane-id", String(id)],
    deadline: .seconds(1),
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024
)
```

Require exit status zero; activation stdout is ignored after the bounded runner owns it.

- [ ] **Step 5: Run CLI and runner tests three times**

Expected: exact path, arguments, limits, deadlines, decoding, and errors pass with no runner regressions.

- [ ] **Step 6: Commit WezTerm CLI control**

```bash
git add HerdrMenubar/System/WezTermCLI.swift \
  HerdrMenubarTests/WezTermCLITests.swift \
  HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: control exact wezterm panes"
```

---

### Task 5: Implement the temporary-title focus adapter

**Files:**
- Create: `HerdrMenubar/System/WezTermFocusAdapter.swift`
- Create: `HerdrMenubarTests/WezTermFocusAdapterTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add project references and deterministic test seams**

Use project IDs `C100...005`, `C100...006`, `C100...00B`, and `C100...00C`.

Define test fakes for:

- `SessionSupervising` title results/errors and exact set/clear sequence;
- `WezTermCLIControlling` queued pane lists, activation gate, and requested IDs;
- `FocusTiming` with manually advanced `ContinuousClock.Instant` and recorded sleeps;
- fixed marker generation (`herdr-menubar-focus:test-token`).

- [ ] **Step 2: Write the complete failing adapter matrix**

Add these tests before production code:

```swift
func testSetsMarkerFindsExactPaneClearsThenActivates() async throws
func testDelayedMarkerPropagationPollsAtFiftyMilliseconds() async throws
func testDuplicateExactMarkersFailClosedAndClear() async
func testNearMatchDoesNotSelectAndTimesOutAfterOneSecond() async
func testNoForegroundClientDoesNotListActivateOrClear() async
func testMethodNotFoundReportsUnsupportedHerdrAndDoesNotList() async
func testMalformedListOutputClearsMarkerBeforeReturningError() async
func testActivationFailureOccursOnlyAfterSuccessfulClear() async
func testCancellationAfterSetRunsCancellationIndependentCleanup() async
func testClearRetriesThreeTimesWithinFiveHundredMilliseconds() async
func testClearFailureRecordsPendingAndDoesNotActivate() async
func testPendingCleanupMustSucceedBeforeNewMarkerForSameSession() async
func testNoForegroundClientDuringPendingCleanupResolvesPendingState() async
func testForgetDropsPendingStateForRemovedSession() async
func testDifferentSessionCanProceedAfterPriorPendingCleanupFailure() async
func testOpaqueMarkerContainsNoSessionPaneSocketOrAgentText() async throws
```

For every test, assert the full action sequence and exact absence of `activatePane` on failure. Do not sleep wall-clock time.

- [ ] **Step 3: Run adapter tests and record RED**

Expected: missing adapter protocol, errors, timing seam, and implementation.

- [ ] **Step 4: Implement adapter interfaces and errors**

Create:

```swift
@MainActor
protocol WezTermSessionFocusing: Sendable {
    func focusAttachedClient(sessionID: SessionID) async throws
    func forget(sessionID: SessionID)
}

enum WezTermFocusError: Error, Equatable, Sendable {
    case noAttachedClient
    case unsupportedHerdr
    case wezTermUnavailable
    case wezTermControlFailed
    case lookupTimedOut
    case ambiguousMarker
    case markerCleanupFailed
}

protocol FocusTiming: Sendable {
    func now() async -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

struct LiveFocusTiming: FocusTiming {
    func now() async -> ContinuousClock.Instant { ContinuousClock().now }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
```

`LiveWezTermFocusAdapter` is `@MainActor`, owns `SessionSupervising`, `WezTermCLIControlling`, timing, a `@Sendable () -> String` marker generator, and `pendingCleanup: Set<SessionID>`.

- [ ] **Step 5: Implement exact handshake and lookup**

The operation must follow this structure:

```swift
func focusAttachedClient(sessionID: SessionID) async throws {
    try await resolvePendingCleanupIfNeeded(sessionID: sessionID)
    try Task.checkCancellation()

    let marker = markerGenerator()
    let setResult: ClientWindowTitleResult
    do {
        setResult = try await supervisor.setClientWindowTitle(
            sessionID: sessionID,
            title: marker
        )
    } catch let error as HerdrAPIError where error.code == "method_not_found" {
        throw WezTermFocusError.unsupportedHerdr
    }
    guard setResult.hasForegroundClient else {
        throw WezTermFocusError.noAttachedClient
    }

    var markerInstalled = true
    do {
        let pane = try await findExactPane(marker: marker)
        try await clearMarkerCancellationIndependently(sessionID: sessionID)
        markerInstalled = false
        try Task.checkCancellation()
        try await cli.activatePane(id: pane.paneID)
    } catch {
        if markerInstalled {
            await ensureCleanupAfterFailure(sessionID: sessionID)
        }
        throw map(error)
    }
}
```

`findExactPane` captures the deadline without relying on `await` precedence:

```swift
let startedAt = await timing.now()
let deadline = startedAt.advanced(by: .seconds(1))
```

Each iteration lists panes, filters with exact `title == marker`, returns one match, throws `.ambiguousMarker` for more than one, checks cancellation and deadline, then sleeps 50 milliseconds.

- [ ] **Step 6: Implement cancellation-independent bounded cleanup**

Create cleanup in a new owned unstructured task so parent cancellation does not skip it, and always await that task:

```swift
private func clearMarkerCancellationIndependently(
    sessionID: SessionID
) async throws {
    let task = Task { @MainActor [self] in
        try await clearMarkerWithRetries(sessionID: sessionID)
    }
    try await task.value
}
```

`clearMarkerWithRetries` makes at most three attempts. `reason == "cleared"` and `reason == "no_foreground_client"` both resolve cleanup and remove the pending flag. Between failed attempts, use a cleanup timing path that is not canceled with the selection and waits 100 milliseconds. Do not exceed 500 milliseconds total. On exhaustion, insert the session into `pendingCleanup` and throw `.markerCleanupFailed`.

Before a new marker for the same session, run the same bounded cleanup. If it still fails, reject the new handshake without calling set/list/activate. `forget(sessionID:)` removes the pending entry; `AgentStore` will call it on `.removed` so a recreated stable session ID cannot inherit stale cleanup state. Pending state is memory-only and bounded by discovered/clicked session IDs.

- [ ] **Step 7: Run adapter tests twenty times**

Expected: all success, timeout, cancellation, ambiguity, cleanup, pending, removal, and isolation cases pass deterministically with no wall-clock sleeps.

- [ ] **Step 8: Commit the focus adapter**

```bash
git add HerdrMenubar/System/WezTermFocusAdapter.swift \
  HerdrMenubarTests/WezTermFocusAdapterTests.swift \
  HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: map herdr sessions to wezterm panes"
```

---

### Task 6: Serialize row selection and wire production composition

**Files:**
- Modify: `HerdrMenubar/Status/AgentStore.swift:89-242`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift:29-47`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift:125-235,430-605`

- [ ] **Step 1: Replace the selection tests with a failing orchestration matrix**

Add `RecordingWezTermFocuser` with a cancellation-aware gate, recorded session IDs, injected errors, and `forget` calls. Update every `AgentStore` construction to inject it.

Add or replace tests:

```swift
func testWezTermSelectionFocusesHerdrThenTabThenAppThenRefreshes() async
func testNonWezTermSelectionSkipsAdapterAndPreservesGenericActivation() async
func testHerdrFocusFailureSkipsAdapterActivationAndRefresh() async
func testNoAttachedTabShowsPartialErrorAndStillRefreshesOwningSession() async
func testUnsupportedHerdrShowsUpdateErrorAndStillRefreshes() async
func testWezTermControlFailureStillRefreshesOnce() async
func testMacOSActivationFailureStillRefreshesOnce() async
func testRapidSecondSelectionCancelsAndAwaitsFirstFinalization() async
func testSupersededSelectionCannotActivateOrPublishError() async
func testStopCancelsAndAwaitsSelectionBeforeSupervisorStop() async
func testRemovedSessionForgetsPendingWezTermCleanup() async
```

The main success sequence is exactly:

```swift
[
  "focus:work:p",
  "wezterm:work",
  "activate:com.github.wez.wezterm",
  "refresh:work"
]
```

For rapid selection, block the first adapter after its Herdr focus, start the second selection, and assert the second `pane.focus` has not occurred. Release cancellation cleanup; assert first refresh completes, then second focus/adapter/activation/refresh proceeds. Only the second generation may set `transientError`.

- [ ] **Step 2: Run AgentStore tests and record RED**

Expected: initializer and selection ownership APIs are missing; old direct selection cannot satisfy adapter or serialization assertions.

- [ ] **Step 3: Add adapter dependency and owned selection lifecycle**

Add:

```swift
private let wezTermFocuser: any WezTermSessionFocusing
private var selectionTask: Task<Void, Never>?
private var selectionGeneration = UUID()
```

Make the initializer require `wezTermFocuser`; update all test and production call sites explicitly rather than adding a production no-op default.

Implement `select` as an owned latest-wins task:

```swift
func select(_ item: AgentMenuItem) async {
    let generation = UUID()
    selectionGeneration = generation
    transientError = nil

    let predecessor = selectionTask
    predecessor?.cancel()
    let task = Task { [weak self] in
        await predecessor?.value
        guard let self, self.ownsSelection(generation) else { return }
        await self.performSelection(item, generation: generation)
    }
    selectionTask = task
    await task.value
    if selectionGeneration == generation { selectionTask = nil }
}
```

`ownsSelection` checks generation and `!Task.isCancelled` for activation/error mutations. `performSelection` tracks `didFocusPane`. A failed `pane.focus` publishes the existing session-qualified error only when current and returns without refresh. After a successful focus, it calls the adapter only when the current preference equals `WezTermCLIConstants.bundleIdentifier`; other terminals skip it. It maps adapter errors to:

```text
Focused the pane in <session>, but no attached WezTerm tab was found.
Focused the pane in <session>, but this Herdr session must be updated for WezTerm tab focus.
Focused the pane in <session>, but WezTerm could not be controlled.
Focused the pane in <session>, but the temporary WezTerm focus marker could not be cleared.
```

Whether adapter or macOS activation succeeds, fails, or is canceled, call `supervisor.refresh(sessionID:)` exactly once after successful `pane.focus`, before the selection task finishes. Suppress stale user-visible errors after cancellation, but do not skip this refresh.

- [ ] **Step 4: Integrate selection ownership with store stop and session removal**

At the beginning of `stop()`, invalidate `selectionGeneration`, capture/cancel `selectionTask`, and include `await selection?.value` before `supervisor.stop()`. This ensures marker cleanup and the final refresh cannot use a stopped supervisor.

In `.removed(let id)`, call:

```swift
wezTermFocuser.forget(sessionID: id)
sessions.removeValue(forKey: id)
```

No other discovery/unavailable event clears pending cleanup; a restart within grace retains the stable session and gets one bounded cleanup sequence on the next click.

- [ ] **Step 5: Compose the live components**

In `HerdrMenubarApp.init`, construct in this order:

```swift
let supervisor = SessionSupervisor(
    discovery: SessionDiscovery(),
    clientFactory: LiveSessionClientFactory()
)
let processRunner = BoundedProcessRunner()
let wezTermCLI = LiveWezTermCLI(processRunner: processRunner)
let wezTermFocuser = LiveWezTermFocusAdapter(
    supervisor: supervisor,
    cli: wezTermCLI
)
let preferences = Preferences()
let store = AgentStore(
    supervisor: supervisor,
    terminalActivator: TerminalActivationService(),
    wezTermFocuser: wezTermFocuser,
    preferences: preferences
)
```

Keep the current event-subscribe-before-supervisor-start and selection-stop-before-supervisor-stop rules.

- [ ] **Step 6: Run store tests twenty times and full tests once**

Expected: latest-wins selection, start/stop lifecycle, all aggregate presentation tests, and the full suite pass without timing flakes.

- [ ] **Step 7: Run an ordinary Debug app build**

```bash
xcodebuild build \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -configuration Debug \
  -destination 'platform=macOS'
```

Expected: build succeeds with no main-actor or Swift 6 sendability warnings from the new composition.

- [ ] **Step 8: Commit store and app integration**

```bash
git add HerdrMenubar/Status/AgentStore.swift \
  HerdrMenubar/App/HerdrMenubarApp.swift \
  HerdrMenubarTests/AgentStoreTests.swift
git commit -m "feat: focus owning wezterm session on selection"
```

---

### Task 7: Prove subprocess and two-session behavior, document, install, and smoke-test

**Files:**
- Create: `HerdrMenubarTests/WezTermSubprocessIntegrationTests.swift`
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`
- Modify: `README.md:25-45,100-120`

- [ ] **Step 1: Add the subprocess integration test reference**

Use project IDs `C100...00D` and `C100...00E` in the test group and test Sources phase.

- [ ] **Step 2: Write a real subprocess fake-WezTerm app test**

Create a short temporary bundle:

```text
/tmp/hm-wz-<8 hex>/WezTerm.app/Contents/MacOS/wezterm
```

The executable script must inspect its arguments:

- `cli list --format json`: return a state-file-controlled JSON array;
- `cli activate-pane --pane-id N`: append `N` to an activation log and exit zero;
- any other arguments: write a diagnostic to stderr and exit 64.

Add:

```swift
func testLiveCLIListsAndActivatesThroughExactBundleSibling() async throws
func testLiveAdapterPollsFakeCLIThenClearsAndActivates() async throws
func testLiveCLIReapsTimedOutFakeProcess() async
```

The adapter test returns `[]` on the first list call and one exact marker pane on the second, proving real process invocation, delayed visibility, JSON capture, and activation logging. Use an injected bundle resolver pointing at the temporary app. Teardown removes the bundle and asserts no child PID remains.

- [ ] **Step 3: Extend the two-socket integration server for title control**

Add request handling to `FakeHerdrServer`:

```text
client.window_title.set   -> client_window_title changed=true reason=set
client.window_title.clear -> client_window_title changed=true reason=cleared
```

Record the current title and every set/clear action actor-isolated. Create an `IntegrationWezTermCLI` whose pane list maps each fake server's current marker to a distinct WezTerm pane ID.

- [ ] **Step 4: Write the cross-session tab-routing test**

Add:

```swift
func testDuplicatePaneIDsFocusOwningHerdrServerAndOwningWezTermPane() async throws
```

Start default and named fake Unix-socket servers, both with pane ID `duplicate`, and assign WezTerm pane IDs 41 and 82. Construct the real supervisor, real adapter, fake CLI bridge, and `AgentStore`. Select the named item and assert:

```swift
XCTAssertEqual(await namedServer.focusedPaneIDs, ["duplicate"])
XCTAssertEqual(await defaultServer.focusedPaneIDs, [])
XCTAssertEqual(await wezTermCLI.activatedPaneIDs, [82])
XCTAssertEqual(await namedServer.windowTitleActions, [
    .set("herdr-menubar-focus:integration"), .clear
])
XCTAssertEqual(await defaultServer.windowTitleActions, [])
```

Then select default and assert activation appends 41. Stop the store and both servers deterministically.

- [ ] **Step 5: Run integration tests five times**

Run `WezTermSubprocessIntegrationTests` and `MultiSessionIntegrationTests` five consecutive times.

Expected: no subprocess, Unix socket, `/tmp/hm-*`, or app-process leak; exact activation order every run.

- [ ] **Step 6: Update README behavior and requirements**

Replace the row-selection paragraph with:

```markdown
Selecting a row sends `pane.focus` to that row's owning Herdr session. When WezTerm is selected, Herdr Menubar also switches to the existing WezTerm tab containing that session's foreground attached client. It never opens a new tab when no client is attached; the menu reports that partial-focus condition instead. Other recognized terminals retain application-level activation without session-aware tab selection.
```

State that session-aware WezTerm tab focus is verified with Herdr 0.7.3 or newer and requires the installed WezTerm app's `Contents/MacOS/wezterm` CLI. Clarify that the adapter runs only on click and installs no helper, shell hook, or WezTerm configuration.

- [ ] **Step 7: Run complete automated validation**

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests

xcodebuild build \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -configuration Release \
  -destination 'platform=macOS'

xcodebuild analyze \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS'

plutil -lint HerdrMenubar.xcodeproj/project.pbxproj
git diff --check
```

Expected: all tests pass; Release build and analysis succeed; project and diff checks are clean. Scan production logs for `.public` interpolation of session names, pane IDs, marker strings, executable paths, CLI output, or underlying errors; expected result is no match.

- [ ] **Step 8: Install the Release build and perform a real two-tab WezTerm smoke test**

Run:

```bash
./scripts/install.sh
```

With default and named Herdr 0.7.3+ sessions attached in two existing tabs of one WezTerm instance, verify:

```text
[ ] clicking the default row selects the default tab and exact Herdr pane
[ ] clicking the named row selects the named tab and exact Herdr pane
[ ] duplicate pane IDs still route to the owning session/tab
[ ] two clients attached to one session select Herdr's most recently active client
[ ] detaching the only client shows the no-attached-tab error and creates no tab
[ ] rapid alternating clicks finish on the final clicked row
[ ] no temporary marker remains after success or an ordinary handled failure
[ ] another configured terminal still receives generic app activation only
[ ] Quit ends Herdr Menubar within five seconds with no wezterm child process
```

Record the ordinary app PID and bound the observation window to 60 seconds. Do not automate clicks against the user's live tabs unless the user is present for the smoke test; automated correctness comes from the fake executable and two-socket integration tests.

- [ ] **Step 9: Commit integration coverage and documentation**

```bash
git add HerdrMenubarTests/WezTermSubprocessIntegrationTests.swift \
  HerdrMenubarTests/MultiSessionIntegrationTests.swift \
  HerdrMenubar.xcodeproj/project.pbxproj \
  README.md
git commit -m "test: verify wezterm session focus end to end"
```

## Plan self-review checklist

- [x] Every goal and acceptance criterion in the design maps to Tasks 1–7.
- [x] Herdr title wire shapes and `method_not_found` behavior map to Tasks 1–2.
- [x] Direct executable invocation, output caps, deadline, cancellation, forced kill, pipe drain, and reap map to Task 3.
- [x] Exact `Contents/MacOS/wezterm` resolution and no `$PATH` fallback map to Task 4.
- [x] Exact marker matching, clear-before-activate, ambiguity, timeout, cancellation-independent cleanup, and pending cleanup map to Task 5.
- [x] Latest-click-wins, refresh-after-successful-pane-focus, non-WezTerm fallback, stop ownership, and removed-session cleanup map to Task 6.
- [x] Real subprocess, two session sockets, duplicate pane IDs, documentation, full validation, installer, and manual smoke map to Task 7.
- [x] No background helper, shell hook, WezTerm config, tab spawning, terminal picker removal, or non-WezTerm session targeting is introduced.
- [x] Placeholder-pattern scan is clean.
- [x] Type and method names are consistent between their defining task and every later use.
