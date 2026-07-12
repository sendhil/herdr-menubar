# Herdr Menubar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native SwiftUI menu-bar-only macOS companion that reflects Herdr agent attention state and focuses the selected pane in the user's configured terminal.

**Architecture:** A SwiftUI `MenuBarExtra` renders an observable main-actor `AgentStore`. A `HerdrClient` actor owns Unix-domain socket transport, JSON-line framing, request correlation, subscriptions, snapshot refreshes, and reconnection; small system services own terminal activation, preferences, and `SMAppService`.

**Tech Stack:** Swift 6, SwiftUI, Observation, Network.framework, Foundation, AppKit, ServiceManagement, OSLog, XCTest, Xcode 26; no third-party dependencies.

## Global Constraints

- Target the current macOS SDK; supporting older macOS releases is out of scope.
- Use SwiftUI `MenuBarExtra`; do not add a normal application window.
- Use only Herdr's public API socket, never its private TUI client socket.
- Herdr owns semantic status and seen state; do not persist or locally acknowledge pane state.
- Persist only the selected terminal bundle identifier and Launch at Login user preference.
- Default the selected terminal to WezTerm (`com.github.wez.wezterm`).
- Launch at Login is off by default and uses `SMAppService`.
- Add no third-party dependencies.
- Use unified logging and concise in-menu errors; do not add modal alerts.

---

## File map

```text
HerdrMenubar.xcodeproj/project.pbxproj                  Xcode targets and build settings
HerdrMenubar/Info.plist                                 Menu-bar-only bundle metadata
HerdrMenubar/HerdrMenubar.entitlements                  App sandbox/network policy
HerdrMenubar/App/HerdrMenubarApp.swift                  MenuBarExtra composition root
HerdrMenubar/Herdr/APIModels.swift                      Public wire request/response models
HerdrMenubar/Herdr/JSONLineFramer.swift                 Partial/multiple read framing
HerdrMenubar/Herdr/SocketPathResolver.swift             Public Herdr socket discovery
HerdrMenubar/Herdr/HerdrConnection.swift                Connection protocol + NWConnection adapter
HerdrMenubar/Herdr/HerdrClient.swift                    Actor, requests, bootstrap, events, reconnect
HerdrMenubar/Status/AgentStore.swift                    UI state, grouping, actions, refresh coalescing
HerdrMenubar/Menu/MenuBarIcon.swift                     Three icon modes and count rendering
HerdrMenubar/Menu/StatusMenu.swift                      Grouped-detail menu
HerdrMenubar/Menu/AgentRow.swift                        One actionable pane row
HerdrMenubar/System/Preferences.swift                   Selected terminal/login intent persistence
HerdrMenubar/System/TerminalActivationService.swift     Installed-terminal discovery and activation
HerdrMenubar/System/LoginItemService.swift              SMAppService wrapper
HerdrMenubarTests/APIModelsTests.swift                  Tolerant wire decoding
HerdrMenubarTests/JSONLineFramerTests.swift             Stream framing
HerdrMenubarTests/SocketPathResolverTests.swift         Path precedence
HerdrMenubarTests/AgentStoreTests.swift                 Derivation, ordering, focus sequence, coalescing
HerdrMenubarTests/HerdrClientTests.swift                Bootstrap, requests, events, disconnect/reconnect
HerdrMenubarTests/PreferencesTests.swift                Defaults and persistence
HerdrMenubarTests/SystemServiceTests.swift              Terminal and login service behavior
HerdrMenubarUITests/HerdrMenubarUITests.swift           Launch smoke test
```

---

### Task 1: Scaffold the menu-bar app and define wire models

**Files:**
- Create: `HerdrMenubar.xcodeproj/project.pbxproj`
- Create: `HerdrMenubar/Info.plist`
- Create: `HerdrMenubar/HerdrMenubar.entitlements`
- Create: `HerdrMenubar/App/HerdrMenubarApp.swift`
- Create: `HerdrMenubar/Herdr/APIModels.swift`
- Create: `HerdrMenubarTests/APIModelsTests.swift`
- Create: `HerdrMenubarUITests/HerdrMenubarUITests.swift`

**Interfaces:**
- Produces: `AgentStatus`, `PaneInfo`, `HerdrRequest<Params>`, `HerdrResponse<Result>`, `PaneListResult`, `PaneFocusResult`, `EventEnvelope`, `HerdrAPIError`.
- Produces app bundle identifier: `dev.herdr.menubar`.
- Consumes no earlier task.

- [ ] **Step 1: Create the Xcode project and targets**

In Xcode, create a macOS App project at the repository root with these exact settings:

```text
Product Name: HerdrMenubar
Team: None
Organization Identifier: dev.herdr
Interface: SwiftUI
Language: Swift
Testing System: XCTest
Storage: None
Deployment Target: macOS 26.0
Targets: HerdrMenubar, HerdrMenubarTests, HerdrMenubarUITests
```

Move the generated app source under `HerdrMenubar/App/`. Set `INFOPLIST_FILE = HerdrMenubar/Info.plist`, `CODE_SIGN_ENTITLEMENTS = HerdrMenubar/HerdrMenubar.entitlements`, `SWIFT_VERSION = 6.0`, and `GENERATE_INFOPLIST_FILE = NO`. Remove generated `ContentView.swift`.

Use this plist body:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Herdr Menubar</string>
  <key>CFBundleDisplayName</key><string>Herdr Menubar</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string></string>
</dict></plist>
```

Use an unsandboxed initial build because connecting to an arbitrary local Unix socket selected by environment/session state is the app's core function:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
```

- [ ] **Step 2: Write failing tolerant-decoding tests**

Create tests that decode a `pane_list` response with `blocked`, `done`, `working`, missing optional labels, and an unknown extra field; decode a `pane_info` focus response; decode an event envelope; and decode an error response.

```swift
import XCTest
@testable import HerdrMenubar

final class APIModelsTests: XCTestCase {
    func testPaneListDecodesStatusesAndIgnoresAdditionalFields() throws {
        let data = Data(#"{"id":"1","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1","terminal_id":"t1","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent":"claude","display_agent":"Claude","title":"API","agent_status":"blocked","revision":7,"future_field":true},{"pane_id":"w1:p2","terminal_id":"t2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"done","revision":8}]}}"#.utf8)
        let response = try JSONDecoder().decode(HerdrResponse<PaneListResult>.self, from: data)
        XCTAssertEqual(response.result?.panes.map(\.agentStatus), [.blocked, .done])
        XCTAssertEqual(response.result?.panes.first?.displayLabel, "API")
    }

    func testUnknownAgentStatusDecodesAsUnknown() throws {
        let data = Data(#"{"pane_id":"p","terminal_id":"t","workspace_id":"w","tab_id":"tab","focused":false,"agent_status":"future","revision":1}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PaneInfo.self, from: data).agentStatus, .unknown)
    }
}
```

- [ ] **Step 3: Run the tests and verify failure**

Run:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/APIModelsTests
```

Expected: compilation fails because the API model types do not exist.

- [ ] **Step 4: Implement the minimal wire models**

Implement explicit `CodingKeys`, optional display fields, and a custom `AgentStatus.init(from:)` that maps unknown strings to `.unknown`. `PaneInfo.displayLabel` must prefer nonempty `title`, then nonempty `label`, then `paneID`.

```swift
enum AgentStatus: String, Codable, Sendable { case idle, working, blocked, done, unknown }

struct PaneInfo: Codable, Identifiable, Equatable, Sendable {
    let paneID: String
    let terminalID: String
    let workspaceID: String
    let tabID: String
    let focused: Bool
    let label: String?
    let agent: String?
    let title: String?
    let displayAgent: String?
    let agentStatus: AgentStatus
    let revision: UInt64
    var id: String { paneID }
    var displayLabel: String { [title, label].compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }.first ?? paneID }
    var agentLabel: String {
        if let displayAgent, !displayAgent.isEmpty { return displayAgent }
        if let agent, !agent.isEmpty { return agent }
        return "Agent"
    }
}

struct PaneListResult: Codable, Sendable {
    let type: String
    let panes: [PaneInfo]
}

struct PaneFocusResult: Codable, Sendable {
    let type: String
    let pane: PaneInfo
}

struct HerdrErrorBody: Codable, Error, Equatable, Sendable { let code: String; let message: String }
struct HerdrResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let id: String
    let result: Result?
    let error: HerdrErrorBody?
}
```

Define request parameter types so encoded requests exactly match:

```json
{"id":"UUID","method":"pane.list","params":{}}
{"id":"UUID","method":"pane.focus","params":{"pane_id":"w1:p1"}}
```

- [ ] **Step 5: Create the minimal `MenuBarExtra` shell**

```swift
import SwiftUI

@main
struct HerdrMenubarApp: App {
    var body: some Scene {
        MenuBarExtra("Herdr", systemImage: "circle") {
            Text("Herdr Menubar")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 6: Run unit tests and launch smoke test**

Run:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
open "$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug/HerdrMenubar.app' -print -quit)"
```

Expected: all tests pass; one menu-bar icon appears and its menu contains Herdr Menubar and Quit; no Dock icon appears.

- [ ] **Step 7: Commit**

```bash
git add HerdrMenubar.xcodeproj HerdrMenubar HerdrMenubarTests HerdrMenubarUITests
git commit -m "feat: scaffold swiftui menu bar app"
```

---

### Task 2: Add socket discovery and JSON-line transport

**Files:**
- Create: `HerdrMenubar/Herdr/JSONLineFramer.swift`
- Create: `HerdrMenubar/Herdr/SocketPathResolver.swift`
- Create: `HerdrMenubar/Herdr/HerdrConnection.swift`
- Create: `HerdrMenubarTests/JSONLineFramerTests.swift`
- Create: `HerdrMenubarTests/SocketPathResolverTests.swift`

**Interfaces:**
- Produces: `JSONLineFramer.append(_:) -> [Data]` and `finish() throws`.
- Produces: `SocketPathResolving.resolve(environment:homeDirectory:) -> URL`.
- Produces: `HerdrConnection` async send/read/close contract, `HerdrConnectionFactory`, and Network.framework adapters.
- Consumes API request bytes from Task 1.

- [ ] **Step 1: Write failing framing and path tests**

Cover one line split across reads, multiple lines in one read, blank lines, CRLF, invalid trailing bytes at EOF, explicit `HERDR_SOCKET_PATH`, named `HERDR_SESSION`, and default `~/.config/herdr/herdr.sock`.

```swift
func testFramerHandlesPartialAndMultipleReads() throws {
    var framer = JSONLineFramer()
    XCTAssertEqual(framer.append(Data(#"{"id":"1""#.utf8)), [])
    XCTAssertEqual(framer.append(Data("}\n{\"id\":\"2\"}\n".utf8)).count, 2)
    XCTAssertNoThrow(try framer.finish())
}

func testSocketPathPrecedence() {
    let resolver = SocketPathResolver()
    XCTAssertEqual(resolver.resolve(environment: ["HERDR_SOCKET_PATH":"/tmp/custom.sock"], homeDirectory: URL(fileURLWithPath: "/Users/me")).path, "/tmp/custom.sock")
    XCTAssertEqual(resolver.resolve(environment: ["HERDR_SESSION":"work"], homeDirectory: URL(fileURLWithPath: "/Users/me")).path, "/Users/me/.config/herdr/sessions/work/herdr.sock")
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/JSONLineFramerTests -only-testing:HerdrMenubarTests/SocketPathResolverTests
```

Expected: compilation fails because the transport types do not exist.

- [ ] **Step 3: Implement framing and path resolution**

`JSONLineFramer` stores pending bytes, splits on byte `0x0A`, strips one terminal `0x0D`, drops empty lines, and throws `FramingError.incompleteLine` when `finish()` sees non-whitespace bytes.

`SocketPathResolver` uses exact precedence:

```swift
if let override = environment["HERDR_SOCKET_PATH"], !override.isEmpty { return URL(fileURLWithPath: override) }
let root = homeDirectory.appending(path: ".config/herdr", directoryHint: .isDirectory)
if let session = environment["HERDR_SESSION"], !session.isEmpty {
    return root.appending(path: "sessions/\(session)/herdr.sock")
}
return root.appending(path: "herdr.sock")
```

- [ ] **Step 4: Implement the connection seam and Network.framework adapter**

Herdr accepts one ordinary request per connection and turns an `events.subscribe` connection into a dedicated event stream. Model a connection, not a multiplexed transport:

```swift
protocol HerdrConnection: Sendable {
    func sendLine(_ data: Data) async throws
    func nextLine() async throws -> Data?
    func close() async
}

protocol HerdrConnectionFactory: Sendable {
    func connect(to socketURL: URL) async throws -> any HerdrConnection
}
```

`NWHerdrConnectionFactory` creates `NWConnection(to: .unix(path: socketURL.path), using: .tcp)`. `NWHerdrConnection` owns one `JSONLineFramer`, queues complete lines from partial/multiple receives, and guards continuations with a private actor. Append `0x0A` to every outbound request exactly once. Convert cancellation into a normal close and transport failures into `TransportError` values. Never reuse an ordinary request connection; retain only the subscription connection for multiple inbound event lines.

- [ ] **Step 5: Run tests and a socket existence check**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/JSONLineFramerTests -only-testing:HerdrMenubarTests/SocketPathResolverTests
test -S "${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" && echo "Herdr socket found" || echo "Herdr socket currently absent (allowed)"
```

Expected: tests pass; socket check reports current local state without affecting the tests.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Herdr HerdrMenubarTests/JSONLineFramerTests.swift HerdrMenubarTests/SocketPathResolverTests.swift
git commit -m "feat: add herdr socket transport"
```

---

### Task 3: Implement the Herdr client lifecycle

**Files:**
- Create: `HerdrMenubar/Herdr/HerdrClient.swift`
- Create: `HerdrMenubarTests/HerdrClientTests.swift`

**Interfaces:**
- Consumes: `HerdrConnectionFactory`, `SocketPathResolving`, and Task 1 wire models.
- Produces: `HerdrClientEvent` (`connected([PaneInfo])`, `snapshot([PaneInfo])`, `disconnected(String)`), `events()`, `start()`, `stop()`, `refresh()`, and `focus(paneID:)`.
- Produces: injectable `BackoffPolicy.delay(attempt:)` and `Sleeper.sleep(for:)`.

- [ ] **Step 1: Write failing client tests with an in-memory transport**

Create an actor-backed fake connection factory that returns independently scripted connections and records decoded outbound JSON. Test:

1. Bootstrap requests an initial `pane.list`, opens one subscription connection with global lifecycle filters plus one `pane.agent_status_changed` filter per discovered pane ID, receives `subscription_started`, then requests a second authoritative `pane.list`.
2. A relevant event triggers a refresh.
3. Event bursts coalesce while a refresh is outstanding.
4. `focus(paneID:)` correlates its response ID and returns the focused pane.
5. Error responses throw `HerdrErrorBody`.
6. Subscription disconnect publishes disconnected; a socket-level ordinary-request failure also invalidates the live snapshot and restarts bootstrap.
7. Reconnect delays are bounded and only one loop exists.
8. Manual retry cancels the delay and reconnects immediately.
9. Malformed and unknown event messages are logged and do not terminate the stream.

```swift
func testBootstrapSubscribesBeforeTakingAuthoritativeSnapshot() async throws {
    let factory = FakeHerdrConnectionFactory()
    let client = HerdrClient(connectionFactory: factory, pathResolver: FakePathResolver(), backoff: .immediate, sleeper: ImmediateSleeper())
    await client.start()
    let initialRequest = try await factory.connection(at: 0)
    let first = try await initialRequest.nextSentObject()
    XCTAssertEqual(first["method"] as? String, "pane.list")
    await initialRequest.replyPaneList(to: first, panes: [pane("w1:p1", .working)])
    let subscription = try await factory.connection(at: 1)
    let second = try await subscription.nextSentObject()
    XCTAssertEqual(second["method"] as? String, "events.subscribe")
    XCTAssertEqual(second.subscriptionPaneIDs, ["w1:p1"])
    await subscription.replySuccess(to: second, result: ["type":"subscription_started"])
    let authoritativeRequest = try await factory.connection(at: 2)
    XCTAssertEqual(try await authoritativeRequest.nextSentObject()["method"] as? String, "pane.list")
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/HerdrClientTests
```

Expected: compilation fails because `HerdrClient` does not exist.

- [ ] **Step 3: Implement request correlation and bootstrap**

The actor owns:

```swift
private var subscriptionConnection: (any HerdrConnection)?
private var subscriptionTask: Task<Void, Never>?
private var reconnectTask: Task<Void, Never>?
private var refreshTask: Task<Void, Never>?
private var refreshRequested = false
```

`request(method:params:as:)` generates a UUID, opens a fresh connection, sends one request line, reads one matching response, times out after five seconds, and closes that connection on success, error, timeout, or cancellation. It rejects a response with a different ID.

Request an initial pane snapshot, then open one separate subscription connection. Encode Herdr's actual `subscriptions` array with global `pane.created`, `pane.closed`, `pane.focused`, `pane.moved`, `pane.exited`, and `pane.agent_detected` objects, plus `{ "type": "pane.agent_status_changed", "pane_id": "..." }` for every discovered pane. After the `subscription_started` acknowledgement, use a fresh ordinary connection for `pane.list` and publish `connected` only from that successful post-subscription snapshot. Debounce pane membership events and replace the subscription using the same initial-snapshot → subscribe → acknowledgement → authoritative-snapshot sequence.

- [ ] **Step 4: Implement event invalidation and coalesced refresh**

Decode pushed messages separately from ID-bearing responses. Status and focus events call `scheduleRefresh()`. Pane creation, closure, move, exit, or detection events call a debounced `scheduleSubscriptionRebuild()`. While a refresh is running, set `refreshRequested`; after it completes, perform at most one additional refresh if requested. Unknown events and malformed pushed lines are logged and ignored.

- [ ] **Step 5: Implement disconnect and reconnect**

Use delays of 0.5, 1, 2, 4, 8, then 15 seconds maximum with ±20% injectable jitter. `start()` and `retryNow()` must be idempotent. `stop()` cancels all tasks, closes transport, and does not reconnect. Clear published live state on disconnect.

- [ ] **Step 6: Run the focused and full tests**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/HerdrClientTests
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
```

Expected: all tests pass with no leaked-continuation runtime warnings.

- [ ] **Step 7: Commit**

```bash
git add HerdrMenubar/Herdr/HerdrClient.swift HerdrMenubarTests/HerdrClientTests.swift
git commit -m "feat: synchronize with herdr agent state"
```

---

### Task 4: Build the observable status store and menu

**Files:**
- Create: `HerdrMenubar/Status/AgentStore.swift`
- Create: `HerdrMenubar/Menu/MenuBarIcon.swift`
- Create: `HerdrMenubar/Menu/StatusMenu.swift`
- Create: `HerdrMenubar/Menu/AgentRow.swift`
- Create: `HerdrMenubarTests/AgentStoreTests.swift`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift`

**Interfaces:**
- Consumes: `HerdrClient.events()`, `refresh()`, and `focus(paneID:)`.
- Produces: `ConnectionState`, `[AgentMenuItem] attentionItems`, `[AgentMenuItem] workingItems`, `attentionCount`, `select(_:)`, and `retry()`.
- Defers terminal activation to Task 5 through `TerminalActivating`.

- [ ] **Step 1: Write failing derivation and action-order tests**

Test that blocked precedes done; ties sort case-insensitively by display label then pane ID; working is separate; idle/unknown are hidden; disconnect clears visible rows; and terminal activation occurs only after successful focus.

```swift
@MainActor
func testGroupsAndSortsAgentRows() {
    let store = AgentStore(client: FakeHerdrClient(), terminalActivator: RecordingActivator())
    store.apply(snapshot: [pane("z", .done), pane("b", .blocked), pane("a", .working), pane("i", .idle)])
    XCTAssertEqual(store.attentionItems.map(\.status), [.blocked, .done])
    XCTAssertEqual(store.workingItems.map(\.paneID), ["a"])
    XCTAssertEqual(store.attentionCount, 2)
}

@MainActor
func testFailedFocusDoesNotActivateTerminal() async {
    let client = FakeHerdrClient(focusError: TestError.failed)
    let activator = RecordingActivator()
    let store = AgentStore(client: client, terminalActivator: activator)
    await store.select(AgentMenuItem(pane: pane("p", .blocked)))
    XCTAssertEqual(activator.activationCount, 0)
    XCTAssertNotNil(store.transientError)
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/AgentStoreTests
```

Expected: compilation fails because `AgentStore` and menu models do not exist.

- [ ] **Step 3: Implement the main-actor store**

Use `@Observable @MainActor final class AgentStore`. Map public statuses without interpreting raw agent state:

```swift
attentionItems = panes.filter { $0.agentStatus == .blocked || $0.agentStatus == .done }
    .map(AgentMenuItem.init)
    .sorted(by: AgentMenuItem.attentionOrder)
workingItems = panes.filter { $0.agentStatus == .working }
    .map(AgentMenuItem.init)
    .sorted(by: AgentMenuItem.labelOrder)
```

On selection, clear the previous transient error, await focus, await terminal activation, then request refresh. If activation fails after focus, retain the refreshed Herdr state and show the activation error; never roll focus back.

- [ ] **Step 4: Implement grouped-detail SwiftUI views**

`MenuBarIcon` renders:

- `circle.dotted` at reduced opacity when disconnected.
- `circle` when connected with zero attention.
- `exclamationmark.circle.fill` plus `Text("\(attentionCount)")` when attention exists.

`StatusMenu` renders disabled uppercase section labels, blocked rows before done rows, a quieter Working section, transient error text in red, settings controls supplied by later services, Retry only when disconnected, and Quit. Every pane row is a `Button` that calls `Task { await store.select(item) }`.

- [ ] **Step 5: Wire the app composition root**

Construct one `HerdrClient` and one `AgentStore`, start the store in `.task`, and stop the client on termination. Replace the shell with:

```swift
MenuBarExtra {
    StatusMenu(store: store)
} label: {
    MenuBarIcon(connectionState: store.connectionState, attentionCount: store.attentionCount)
}
.menuBarExtraStyle(.menu)
```

- [ ] **Step 6: Run tests and manually inspect disconnected UI**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
```

Expected: all tests pass; with Herdr stopped, the icon is dimmed and the menu shows Disconnected, Retry, and Quit without stale pane rows.

- [ ] **Step 7: Commit**

```bash
git add HerdrMenubar/App HerdrMenubar/Status HerdrMenubar/Menu HerdrMenubarTests/AgentStoreTests.swift
git commit -m "feat: show grouped agent status menu"
```

---

### Task 5: Add terminal preferences and activation

**Files:**
- Create: `HerdrMenubar/System/Preferences.swift`
- Create: `HerdrMenubar/System/TerminalActivationService.swift`
- Create: `HerdrMenubarTests/PreferencesTests.swift`
- Create: `HerdrMenubarTests/SystemServiceTests.swift`
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/Menu/StatusMenu.swift`

**Interfaces:**
- Produces: `TerminalApp`, `TerminalCatalog.installedTerminals()`, `TerminalActivating.activate(bundleIdentifier:)`, and observable `Preferences.selectedTerminalBundleIdentifier`.
- Consumes: successful focus action from Task 4.

- [ ] **Step 1: Write failing preference and activation tests**

Use an isolated `UserDefaults(suiteName:)`. Assert default WezTerm bundle ID, persistence, catalog filtering based on an injected bundle lookup, successful activation, missing-app error, and activation-refused error.

```swift
func testTerminalDefaultsToWezTerm() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    XCTAssertEqual(Preferences(defaults: defaults).selectedTerminalBundleIdentifier, "com.github.wez.wezterm")
}

func testCatalogReturnsOnlyInstalledKnownTerminals() {
    let catalog = TerminalCatalog(bundleURL: { $0 == "com.github.wez.wezterm" ? URL(fileURLWithPath: "/Applications/WezTerm.app") : nil })
    XCTAssertEqual(catalog.installedTerminals().map(\.bundleIdentifier), ["com.github.wez.wezterm"])
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/PreferencesTests -only-testing:HerdrMenubarTests/SystemServiceTests
```

Expected: compilation fails because system service types do not exist.

- [ ] **Step 3: Implement preferences and terminal catalog**

Known terminals, in picker order:

```swift
[
 TerminalApp(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm"),
 TerminalApp(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
 TerminalApp(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
 TerminalApp(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
 TerminalApp(name: "Kitty", bundleIdentifier: "net.kovidgoyal.kitty"),
 TerminalApp(name: "Alacritty", bundleIdentifier: "org.alacritty")
]
```

Use `NSWorkspace.urlForApplication(withBundleIdentifier:)` for discovery. Persist under key `selectedTerminalBundleIdentifier`.

- [ ] **Step 4: Implement terminal activation**

Resolve the app URL, then call:

```swift
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
```

Map missing application and open failure into concise typed `TerminalActivationError` descriptions suitable for the menu.

- [ ] **Step 5: Add the terminal picker and complete selection flow**

Add a `Picker("Terminal", selection: ...)` containing installed terminals. If the saved terminal is unavailable, show it as unavailable plus installed alternatives. Bind selection to `Preferences`; `AgentStore.select` reads the current preference only after focus succeeds.

- [ ] **Step 6: Run tests and validate WezTerm activation**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
mdfind 'kMDItemCFBundleIdentifier == "com.github.wez.wezterm"' | head -1
```

Expected: tests pass; the second command prints WezTerm's app path on the target machine. With a live Herdr pane, selecting its row focuses the pane and brings WezTerm forward.

- [ ] **Step 7: Commit**

```bash
git add HerdrMenubar/System HerdrMenubar/Status/AgentStore.swift HerdrMenubar/Menu/StatusMenu.swift HerdrMenubarTests
git commit -m "feat: activate the configured terminal"
```

---

### Task 6: Add Launch at Login and finish lifecycle polish

**Files:**
- Create: `HerdrMenubar/System/LoginItemService.swift`
- Modify: `HerdrMenubar/System/Preferences.swift`
- Modify: `HerdrMenubar/Menu/StatusMenu.swift`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift`
- Modify: `HerdrMenubarTests/SystemServiceTests.swift`
- Modify: `HerdrMenubarTests/PreferencesTests.swift`
- Modify: `README.md`

**Interfaces:**
- Produces: `LoginItemManaging.status`, `setEnabled(_:) async throws`, and a test adapter over `SMAppService.mainApp`.
- Consumes the settings area from Task 4.

- [ ] **Step 1: Write failing login-item tests**

Inject a fake registration backend. Test default-off intent, successful register/unregister, failure retaining system-confirmed state, and mapping `.enabled`, `.requiresApproval`, `.notRegistered`, and `.notFound` into menu state.

```swift
@MainActor
func testRegistrationFailureKeepsConfirmedDisabledState() async {
    let backend = FakeLoginBackend(status: .notRegistered, registerError: TestError.failed)
    let service = LoginItemService(backend: backend)
    do {
        try await service.setEnabled(true)
        XCTFail("expected registration failure")
    } catch {
        XCTAssertEqual(error as? TestError, .failed)
    }
    XCTAssertFalse(service.isEnabled)
}
```

- [ ] **Step 2: Run tests and verify failure**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/SystemServiceTests -only-testing:HerdrMenubarTests/PreferencesTests
```

Expected: compilation fails because login item service types do not exist.

- [ ] **Step 3: Implement the `SMAppService` wrapper**

The production backend delegates to `SMAppService.mainApp.status`, `.register()`, and `.unregister()`. `setEnabled` performs the operation, rereads status, and updates UI only from that reread. Treat `.requiresApproval` as not enabled and expose “Allow in System Settings” help text rather than claiming success.

- [ ] **Step 4: Add the menu toggle**

Add a `Toggle("Launch at Login", isOn:)` whose setter starts an async operation. Disable it while changing registration. On failure, restore the system-confirmed value and display a concise transient error. Do not persist a successful-looking value before `SMAppService` confirms it.

- [ ] **Step 5: Add logging and README run instructions**

Create subsystem loggers for transport, synchronization, and system actions using `Logger(subsystem: "dev.herdr.menubar", category: ...)`. Log connection transitions, malformed-message summaries without pane output, focus failures, activation failures, and login-item failures.

Document exact local use:

```markdown
## Development

Open `HerdrMenubar.xcodeproj` in Xcode and run the `HerdrMenubar` scheme. The app has no Dock icon; use its menu-bar icon to configure the terminal (WezTerm by default), enable Launch at Login, retry Herdr connection, or quit.

Herdr Menubar follows `HERDR_SOCKET_PATH`, then `HERDR_SESSION`, then `~/.config/herdr/herdr.sock`.
```

- [ ] **Step 6: Run all automated validation**

```bash
xcodebuild clean test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
git diff --check
```

Expected: tests and static analysis pass; `git diff --check` prints nothing.

- [ ] **Step 7: Run the real-Herdr acceptance matrix**

With a local Herdr session, verify each row and record results in the commit message notes or implementation handoff:

```text
[ ] Herdr absent -> dimmed icon, no stale agents, Retry works
[ ] Herdr starts -> app reconnects without relaunch
[ ] working pane -> appears only under Working
[ ] blocked pane -> appears under Needs Attention and increments count
[ ] unseen done pane -> appears after Blocked and increments count
[ ] done row click -> exact pane focused, WezTerm activated, row disappears after idle refresh
[ ] blocked row click -> exact pane focused, WezTerm activated, row remains until Herdr unblocks
[ ] Herdr restart -> one reconnect loop and recovered snapshot
[ ] missing configured terminal -> actionable menu error
[ ] Launch at Login -> enable and disable both match macOS settings
```

- [ ] **Step 8: Commit**

```bash
git add HerdrMenubar README.md HerdrMenubarTests
git commit -m "feat: add login launch and lifecycle polish"
```

---

### Task 7: Final review against the approved design

**Files:**
- Modify only files required by review findings.

**Interfaces:**
- Consumes the complete app from Tasks 1–6.
- Produces a clean, documented, locally runnable first version.

- [ ] **Step 1: Audit every design requirement**

Compare implementation with `docs/superpowers/specs/2026-07-11-herdr-menubar-design.md` and explicitly confirm: menu-bar-only lifecycle, three icon modes, grouped detail, authoritative snapshots, blocked/done count, exact focus-before-activation order, WezTerm default, installed-terminal picker, optional Launch at Login, no pane persistence, reconnection, concise errors, unified logging, and no third-party packages.

- [ ] **Step 2: Inspect repository and project cleanliness**

```bash
git status --short
find . -maxdepth 3 \( -name DerivedData -o -name xcuserdata -o -name '*.xcuserstate' \) -print
xcodebuild -list -project HerdrMenubar.xcodeproj
```

Expected: only intentional source changes are listed; no user-specific Xcode state is tracked; app and test schemes are discoverable.

- [ ] **Step 3: Run final validation**

```bash
xcodebuild clean test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
git diff --check
git status --short
```

Expected: tests and analysis pass, whitespace check is clean, and status contains only deliberate review fixes if any.

- [ ] **Step 4: Commit review fixes if needed**

If Step 3 required source changes:

```bash
git add HerdrMenubar HerdrMenubarTests HerdrMenubarUITests README.md
git commit -m "fix: address final menubar review"
```

If no changes were required, do not create an empty commit.

---

### Task 8: Mirror Herdr agent-panel labels

**Files:**
- Modify: `HerdrMenubar/Herdr/APIModels.swift`
- Modify: `HerdrMenubar/Herdr/HerdrClient.swift`
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/Menu/AgentRow.swift`
- Modify: `HerdrMenubarTests/APIModelsTests.swift`
- Modify: `HerdrMenubarTests/HerdrClientTests.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`

**Interfaces:**
- Produces presentation snapshots joining panes with `workspace.list` and `tab.list` metadata.
- Produces Herdr-compatible primary labels: workspace, or `workspace · tab` for multi-tab workspaces.
- Keeps pane IDs only as focus targets and final visible fallbacks.

- [ ] **Step 1: Add failing metadata decoding and label tests**

Test public `workspace_list` and `tab_list` response decoding. Test single-tab `dotfiles-mac`, multi-tab `Herdr Menubar · server`, metadata fallback to pane title/label, and final fallback to pane ID. Assert secondary context is `done · Pi`.

- [ ] **Step 2: Verify focused tests fail**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/APIModelsTests -only-testing:HerdrMenubarTests/AgentStoreTests
```

Expected: failures because workspace/tab response models and joined labels do not exist.

- [ ] **Step 3: Implement public metadata models and snapshot join**

Decode `workspace.list` and `tab.list` using Herdr's public response fields. During each authoritative refresh, collect panes, workspaces, and tabs, then join by `workspace_id` and `tab_id`. A workspace is multi-tab when its metadata reports more than one tab or the snapshot contains multiple distinct tab IDs for that workspace.

- [ ] **Step 4: Render Herdr-compatible labels**

Primary label order: joined workspace display label with optional tab suffix; pane title; pane label; pane ID. Secondary context order: lowercase semantic status, ` · `, effective display agent. Keep the primary label sufficient on its own because native `.menu` may suppress secondary text.

- [ ] **Step 5: Validate without UI tests**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
```

Expected: all unit tests pass and build succeeds. Relaunch the ordinary app process and visually confirm workspace labels replace public pane IDs.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar HerdrMenubarTests HerdrMenubar.xcodeproj docs/superpowers/specs/2026-07-11-herdr-menubar-design.md
git commit -m "feat: mirror herdr agent labels"
```
