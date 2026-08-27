# Herdr Menubar Global Keyboard Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two initially unassigned, user-configurable global shortcuts that toggle the native Herdr status menu and refocus the exact target of the newest accepted notification in the current app run.

**Architecture:** Replace the unsupported programmatic `MenuBarExtra` shell with an AppKit `NSStatusItem`/`NSMenu` owned by an explicit application runtime. Use `KeyboardShortcuts` 3.0.1 only for shortcut values, persistence, Carbon registration, and event delivery; use an in-repository first-responder recorder because the package recorder is broken on macOS 26. Notification delivery records one monotonic in-memory target, and both notification clicks and the shortcut enter the same `AgentStore` latest-selection-wins path.

**Tech Stack:** Swift 6, Swift concurrency, Observation, AppKit, SwiftUI `NSViewRepresentable`, UserNotifications, KeyboardShortcuts 3.0.1, XCTest, Xcode 26/macOS 26.

**Design spec:** `docs/superpowers/specs/2026-08-27-herdr-menubar-global-keyboard-shortcuts-design.md`

---

## Worktree and baseline

Implement only in:

```text
/Users/sendhil/src/herdr-menubar/.worktrees/global-keyboard-shortcuts
```

Branch: `codex/global-keyboard-shortcuts`

The pre-change baseline is 278 non-UI tests with zero failures. Xcode test/build commands need filesystem escalation because DerivedData and test services live outside the repository sandbox.

## File map

| File | Responsibility |
| --- | --- |
| `HerdrMenubar/Notifications/NotificationModels.swift` | Add accepted/suppressed delivery result and latest-target recording seam |
| `HerdrMenubar/Notifications/LatestNotificationTargetStore.swift` | In-memory monotonic accepted target; never persisted |
| `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift` | Assign per-submission ordinals and record only accepted requests |
| `HerdrMenubar/Notifications/NativeNotificationService.swift` | Return `.accepted` only after `UNUserNotificationCenter.add`; return `.suppressed` for blocked settings |
| `HerdrMenubar/Status/AgentStore.swift` | Expose one target-selection entry point shared by notification responses and shortcuts |
| `HerdrMenubar/Shortcuts/ShortcutModels.swift` | Stable actions, raw shortcut value, registrar/event protocols, live KeyboardShortcuts adapter |
| `HerdrMenubar/Shortcuts/ShortcutAssignmentController.swift` | Validate, save, verify, roll back, retry, and present two assignments |
| `HerdrMenubar/Shortcuts/NativeShortcutRecorder.swift` | macOS 26-safe first-responder recorder control and SwiftUI wrapper |
| `HerdrMenubar/Shortcuts/GlobalShortcutController.swift` | Own two key-up consumers and route lifecycle-safe actions |
| `HerdrMenubar/Shortcuts/KeyboardShortcutSettingsView.swift` | Two recorders, clear buttons, help, and inline errors |
| `HerdrMenubar/Shortcuts/KeyboardShortcutSettingsWindowController.swift` | Own and reuse one settings window |
| `HerdrMenubar/Menu/StatusMenuPresentation.swift` | Immutable native-menu/icon snapshot and stable action identities |
| `HerdrMenubar/Menu/StatusItemController.swift` | Own status item/menu, apply snapshots, defer tracked-menu mutation, and toggle open/closed |
| `HerdrMenubar/App/ApplicationRuntime.swift` | Compose live graph, observe models, and serialize launch/shutdown |
| `HerdrMenubar/App/HerdrMenubarApp.swift` | Delegate hooks plus inert SwiftUI scene; remove `MenuBarExtra` `.task` ownership |
| `HerdrMenubar/Menu/StatusMenu.swift` | Delete after native menu parity is green |
| `HerdrMenubar/Menu/AgentRow.swift` | Delete after native agent-row parity is green |
| `HerdrMenubarTests/*Shortcut*Tests.swift` | Assignment, recorder, event lifecycle, target ordering, and settings-window tests |
| `HerdrMenubarTests/StatusMenuPresentationTests.swift` | Exhaustive native menu parity and action identity |
| `HerdrMenubarTests/StatusItemControllerTests.swift` | Menu tracking/toggle/observation application behavior |
| `HerdrMenubarTests/ApplicationRuntimeTests.swift` | Launch, activation, stop barrier, observation re-arm, and late-callback rejection |
| `HerdrMenubarTests/MultiSessionIntegrationTests.swift` | Two-session accepted-delivery → shortcut → exact focus integration |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Exact package pin, product link, Shortcuts group, and source/test membership |
| `HerdrMenubar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Reproducible 3.0.1 dependency pin |
| `README.md` | Configuration, current-run target semantics, no-permission behavior, and limitations |

Use the `E300…` ID family for all new Xcode objects. Reserve `E30000000000000000000001` for the Shortcuts group, `…24` for the package product dependency, `…25` for its build file, `…26` for the Frameworks phase, and `…27` for the remote package reference. Allocate file-reference/build-file pairs sequentially from `…02/…03` through `…22/…23`. Never reuse the existing `D200…` notification IDs.

## Shared commands

Focused test:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/<TestClass>
```

Full non-UI suite:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

Every production task starts with a genuine compiling RED. Use explicit gates/continuations for concurrency tests; do not use fixed sleeps or fixed `Task.yield()` counts as proof of ordering.

---

### Task 1: Record only the newest accepted notification request

**Files:**
- Create: `HerdrMenubar/Notifications/LatestNotificationTargetStore.swift`
- Create: `HerdrMenubarTests/LatestNotificationTargetStoreTests.swift`
- Modify: `HerdrMenubar/Notifications/NotificationModels.swift`
- Modify: `HerdrMenubar/Notifications/NativeNotificationService.swift`
- Modify: `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift`
- Modify: `HerdrMenubarTests/NativeNotificationServiceTests.swift`
- Modify: `HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write delivery-result and monotonic-target RED tests**

Add these exact behavioral cases:

```swift
func testSuppressedDeliveryReturnsSuppressedAndAddsNothing() async throws {
    let backend = FakeNotificationCenterBackend(settings: .denied)
    let service = NativeNotificationService(backend: backend)

    let result = try await service.deliver(blockedEvent(), sound: true)

    XCTAssertEqual(result, .suppressed)
    XCTAssertEqual(backend.addedRequests, [])
}

func testAcceptedDeliveryReturnsAcceptedOnlyAfterBackendAdd() async throws {
    let backend = FakeNotificationCenterBackend(settings: .authorized)
    let service = NativeNotificationService(backend: backend)

    let result = try await service.deliver(blockedEvent(), sound: false)

    XCTAssertEqual(result, .accepted)
    XCTAssertEqual(backend.addedRequests.count, 1)
}

func testStoreRejectsOlderAcceptedOrdinalAndResetClearsMemory() async {
    let store = LatestNotificationTargetStore()
    let old = NotificationSelectionTarget(sessionID: .default, paneID: "old")
    let newest = NotificationSelectionTarget(sessionID: .named("work"), paneID: "new")

    await store.record(old, ordinal: 1)
    await store.record(newest, ordinal: 3)
    await store.record(old, ordinal: 2)
    XCTAssertEqual(await store.latest(), newest)

    await store.reset()
    XCTAssertNil(await store.latest())
}
```

Add a controlled notification service test for the required three-event overlap: `a1` submission blocks, `b1` submits and accepts, `a1` accepts, then `a2` submits. Assert service submission order is `a1, b1, a2`, recorder calls are `b1=2, a1=1, a2=3`, and latest target is `a2`. The service fake must expose explicit `waitForA1Attempt()` and `releaseA1()` gates; the recorder fake must preserve every `(target, ordinal)` call even when its own latest-value rule rejects the older ordinal.

- [ ] **Step 2: Run RED**

Run `NativeNotificationServiceTests`, `LatestNotificationTargetStoreTests`, and `AttentionNotificationCoordinatorTests`.

Expected: compilation fails because `deliver` returns `Void`, delivery result/target store do not exist, and the coordinator has no recorder injection.

- [ ] **Step 3: Add the result and recorder contracts**

Add to `NotificationModels.swift`:

```swift
enum NotificationDeliveryResult: Equatable, Sendable {
    case accepted
    case suppressed
}

protocol LatestNotificationTargetRecording: Sendable {
    func record(_ target: NotificationSelectionTarget, ordinal: UInt64) async
    func latest() async -> NotificationSelectionTarget?
    func reset() async
}

protocol NativeNotificationServing: Sendable {
    func responses() async -> NotificationResponseSubscription
    func requestAuthorization() async throws -> Bool
    func settings() async -> NotificationSystemSettings
    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult
}
```

Create the store with monotonic replacement:

```swift
actor LatestNotificationTargetStore: LatestNotificationTargetRecording {
    private var entry: (ordinal: UInt64, target: NotificationSelectionTarget)?

    func record(_ target: NotificationSelectionTarget, ordinal: UInt64) {
        guard entry == nil || ordinal > entry!.ordinal else { return }
        entry = (ordinal, target)
    }

    func latest() -> NotificationSelectionTarget? { entry?.target }

    func reset() { entry = nil }
}
```

- [ ] **Step 4: Return an explicit native-delivery result**

Change `NativeNotificationService.deliver` so the authorization guard returns `.suppressed`, `backend.add` is awaited unchanged, and the only success return after that await is `.accepted`:

```swift
let settings = await backend.settings()
guard settings.authorization == .authorized, settings.alertsEnabled else {
    return .suppressed
}
// Build the existing request without changing content or privacy.
try await backend.add(request)
return .accepted
```

Update recording/fake notification services to return a configurable result, defaulting to `.accepted`. Existing tests that do not inspect the result should assign it to `_`.

- [ ] **Step 5: Inject the recorder and assign ordinals per submission**

Make `AttentionNotificationCoordinator` require `latestTargetRecorder`. Build the full candidate list before delivery, but increment immediately before each call:

```swift
private let latestTargetRecorder: any LatestNotificationTargetRecording
private var nextDeliveryOrdinal: UInt64 = 0

for event in candidates {
    guard !Task.isCancelled else { return }
    precondition(nextDeliveryOrdinal < .max, "notification delivery ordinal exhausted")
    nextDeliveryOrdinal += 1
    let ordinal = nextDeliveryOrdinal
    do {
        let result = try await service.deliver(event, sound: policy.soundEnabled)
        if result == .accepted {
            await latestTargetRecorder.record(event.target, ordinal: ordinal)
        }
    } catch is CancellationError {
        return
    } catch {
        guard !Task.isCancelled else { return }
        AppLog.systemActions.error(
            "Notification delivery failed: \(error.localizedDescription, privacy: .private)"
        )
    }
}
```

After an `.accepted` result, do not insert a cancellation guard before `record`. Update every coordinator construction with either the real store or a recording fake; do not add a production default.

- [ ] **Step 6: Run GREEN and commit**

Run the three focused suites, then all notification/store/integration tests. Expected: accepted/suppressed behavior and the three-event overlap pass.

```bash
git add HerdrMenubar/Notifications HerdrMenubarTests/LatestNotificationTargetStoreTests.swift HerdrMenubarTests/NativeNotificationServiceTests.swift HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/MultiSessionIntegrationTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: retain latest accepted notification target"
```

---

### Task 2: Share exact target selection between clicks and shortcuts

**Files:**
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`

- [ ] **Step 1: Write direct-target RED tests**

Add cases that call a new `select(_ target:)` entry directly and prove:

```swift
let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "p2")
store.select(target)
await supervisor.waitForFocus(sessionID: .named("work"), paneID: "p2")
XCTAssertEqual(await supervisor.focusCalls, [target])
```

Also cover: no-target action is outside the store; unavailable target is retained across `.discoverySnapshot([])` while its presentation state is in grace; reconnect runs it once; `.removed` abandons it; an unknown target after completed discovery publishes `<session> is unavailable`; a later row selection supersedes the direct target; stopped store ignores it.

- [ ] **Step 2: Run RED**

Run `AgentStoreTests`. Expected: compile failure because only `select(AgentMenuItem)` exists.

- [ ] **Step 3: Expose the shared target entry**

Add this main-actor overload and route the response consumer through it:

```swift
func select(_ target: NotificationSelectionTarget) {
    guard isRunning else { return }
    receiveNotificationTarget(target, generation: eventGeneration)
}
```

In the notification response loop replace the private call with:

```swift
await self?.select(target)
```

Keep `receiveNotificationTarget`, `supersedeSelection`, pending discovery/grace, selection generations, and stop ownership unchanged. Do not make session/pane labels part of routing.

- [ ] **Step 4: Run GREEN, mutation-check, and commit**

Run `AgentStoreTests` 20 times. Temporarily bypass either the grace retention or `.removed` clear and prove its new test fails; restore production before committing.

```bash
git add HerdrMenubar/Status/AgentStore.swift HerdrMenubarTests/AgentStoreTests.swift
git commit -m "refactor: share notification target selection"
```

---

### Task 3: Add the hotkey engine and transactional assignment controller

**Files:**
- Create: `HerdrMenubar/Shortcuts/ShortcutModels.swift`
- Create: `HerdrMenubar/Shortcuts/ShortcutAssignmentController.swift`
- Create: `HerdrMenubarTests/ShortcutAssignmentControllerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`
- Create through package resolution: `HerdrMenubar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

- [ ] **Step 1: Add exact package metadata and resolve it**

Add `XCRemoteSwiftPackageReference` for `https://github.com/sindresorhus/KeyboardShortcuts` with `kind = exactVersion; version = 3.0.1;`, an `XCSwiftPackageProductDependency` named `KeyboardShortcuts`, a Frameworks phase on the app target, and the product build file. Add the Shortcuts group to the main source group. Run:

```bash
xcodebuild -resolvePackageDependencies \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar
```

Expected: `Package.resolved` pins version `3.0.1` and its revision; `xcodebuild -list` succeeds. Do not instantiate `KeyboardShortcuts.Recorder` or `RecorderCocoa` anywhere.

- [ ] **Step 2: Write assignment RED tests**

Define a fake registrar over these domain values and test: both actions initially nil; independent assignment/clear; duplicate rejection; system and main-menu rejection; successful replacement; Carbon failure rolls back old value; failed first assignment rolls back nil; startup-unavailable remains visible; activation retry marks it active; errors are action-scoped; no key text is logged or separately persisted.

Representative assertion:

```swift
registrar.values[.toggleMenu] = old
registrar.enabledCandidates = [old]
let controller = ShortcutAssignmentController(registrar: registrar)

registrar.enabledCandidates.remove(candidate)
controller.assign(candidate, to: .toggleMenu)

XCTAssertEqual(registrar.values[.toggleMenu], old)
XCTAssertEqual(controller.shortcut(for: .toggleMenu), old)
XCTAssertEqual(controller.error(for: .toggleMenu), "That shortcut is unavailable.")
```

- [ ] **Step 3: Run RED**

Run `ShortcutAssignmentControllerTests`. Expected: compilation fails because shortcut domain and controller types are absent.

- [ ] **Step 4: Add the domain and live adapter**

Create these boundaries in `ShortcutModels.swift`:

```swift
import AppKit
import KeyboardShortcuts

enum ShortcutAction: String, CaseIterable, Hashable, Sendable {
    case toggleMenu
    case focusLatestNotification
}

struct ShortcutBinding: Equatable, Hashable, Sendable {
    let carbonKeyCode: Int
    let carbonModifiers: Int

    var modifiers: NSEvent.ModifierFlags {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: carbonKeyCode,
            carbonModifiers: carbonModifiers
        ).modifiers
    }
}

enum GlobalShortcutEvent: Equatable, Sendable { case keyDown, keyUp }

@MainActor
protocol ShortcutRegistering: AnyObject {
    func shortcut(for action: ShortcutAction) -> ShortcutBinding?
    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction)
    func isEnabled(for action: ShortcutAction) -> Bool
    func retryRegistration(for action: ShortcutAction)
    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool
    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool
    func displayString(for shortcut: ShortcutBinding) -> String
    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent>
}
```

`LiveShortcutRegistrar` maps the actions to names with no initial value:

```swift
extension KeyboardShortcuts.Name {
    static let toggleHerdrMenu = Self("toggleHerdrMenu")
    static let focusLatestHerdrNotification = Self("focusLatestHerdrNotification")
}
```

Map raw values through `KeyboardShortcuts.Shortcut(carbonKeyCode:carbonModifiers:)`; use `getShortcut`, `setShortcut`, `isEnabled(for:)`, `enable`, `Shortcut.isTakenBySystem`, `nsMenuItemKeyEquivalent` plus `NSApp.mainMenu`, `description`, and `events(for:)`. Bridge package events into one cancelable `AsyncStream<GlobalShortcutEvent>` whose producer task is canceled from `onTermination`.

- [ ] **Step 5: Implement transactional assignment**

Create an `@Observable @MainActor` controller with cached values, last-known-good values, and per-action errors. Its assignment order is exact:

```swift
func assign(_ candidate: ShortcutBinding?, to action: ShortcutAction) {
    errorMessages[action] = nil
    guard let candidate else {
        registrar.setShortcut(nil, for: action)
        values[action] = nil
        lastKnownGood[action] = nil
        return
    }
    guard validate(candidate, for: action) else { return }

    let previous = lastKnownGood[action] ?? values[action]
    registrar.setShortcut(candidate, for: action)
    guard registrar.isEnabled(for: action) else {
        registrar.setShortcut(previous, for: action)
        values[action] = previous
        errorMessages[action] = "That shortcut is unavailable."
        return
    }
    values[action] = candidate
    lastKnownGood[action] = candidate
}
```

Validation rejects the other action's binding, `isTakenBySystem`, and `conflictsWithMainMenu` with distinct concise inline messages. `refreshRegistrationStatus()` retries persisted non-nil values once, marks enabled values known-good, and leaves unavailable startup values visible rather than clearing them.

- [ ] **Step 6: Run GREEN and commit**

Run the focused suite, `xcodebuild -list`, and an unsigned Debug build. Inspect `Package.resolved` for exactly 3.0.1.

```bash
git add HerdrMenubar/Shortcuts/ShortcutModels.swift HerdrMenubar/Shortcuts/ShortcutAssignmentController.swift HerdrMenubarTests/ShortcutAssignmentControllerTests.swift HerdrMenubar.xcodeproj
git commit -m "feat: manage global shortcut assignments"
```

---

### Task 4: Build the macOS 26-safe native recorder

**Files:**
- Create: `HerdrMenubar/Shortcuts/NativeShortcutRecorder.swift`
- Create: `HerdrMenubarTests/NativeShortcutRecorderTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write synthetic-event RED tests**

Use `NSEvent.keyEvent` to cover mouse focus, Command/Control/Option ordinary keys, unmodified F-keys, Escape cancellation, Delete clearing, invalid bare letters, title refresh after model changes, and accessibility label/value. Call `keyDown(with:)` directly after installing capture/cancel/clear closures so tests cannot depend on a physical keyboard.

```swift
let control = NativeShortcutRecorderControl()
var captured: ShortcutBinding?
control.onCapture = { captured = $0 }
control.keyDown(with: keyEvent(keyCode: 0, modifiers: [.command]))
XCTAssertEqual(captured?.carbonKeyCode, 0)
XCTAssertEqual(captured?.modifiers, [.command])
```

Add a regression asserting the control is not an `NSTextField`, owns no `NSEvent` monitor token, and a separate clear invocation fires exactly once. This directly protects against upstream issue #241.

- [ ] **Step 2: Run RED**

Run `NativeShortcutRecorderTests`. Expected: missing control and representable types.

- [ ] **Step 3: Implement the first-responder control**

Create `NativeShortcutRecorderControl: NSButton` with rounded bezel, `acceptsFirstResponder == true`, mouse focus, and key handling:

```swift
override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
}

override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 53: // Escape
        onCancel?()
    case 51, 117: // Delete / Forward Delete
        onClear?()
    default:
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        let binding = ShortcutBinding(
            carbonKeyCode: shortcut.carbonKeyCode,
            carbonModifiers: shortcut.carbonModifiers
        )
        guard Self.hasRequiredModifierOrIsFunctionKey(binding) else {
            onInvalidBareKey?()
            return
        }
        onCapture?(binding)
    }
}
```

Implement `hasRequiredModifierOrIsFunctionKey` using `binding.modifiers` and the macOS virtual key codes below. Shift alone is not sufficient for an ordinary key:

```swift
private static let functionKeyCodes: Set<Int> = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
    103, 111, 105, 107, 113, 106, 64, 79, 80, 90
]

static func hasRequiredModifierOrIsFunctionKey(_ binding: ShortcutBinding) -> Bool {
    let required: NSEvent.ModifierFlags = [.command, .control, .option]
    return !binding.modifiers.intersection(required).isEmpty
        || functionKeyCodes.contains(binding.carbonKeyCode)
}
```

Do not install `NSEvent.addLocalMonitorForEvents`, a field editor, event tap, or Accessibility API.

Wrap the control in `NativeShortcutRecorder: NSViewRepresentable`, updating its title/accessibility value from the supplied display string and replacing closures on every update.

- [ ] **Step 4: Run GREEN, inspect for forbidden APIs, and commit**

Run the focused suite 20 times. Search the new file for `addLocalMonitor`, `CGEvent.tapCreate`, and `AXIsProcessTrusted`; expected result is none.

```bash
git add HerdrMenubar/Shortcuts/NativeShortcutRecorder.swift HerdrMenubarTests/NativeShortcutRecorderTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: record shortcuts natively on macos 26"
```

---

### Task 5: Route lifecycle-owned global key-up events

**Files:**
- Create: `HerdrMenubar/Shortcuts/GlobalShortcutController.swift`
- Create: `HerdrMenubarTests/GlobalShortcutControllerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write event/lifecycle RED tests**

Use a fake registrar with one continuation per action and a gated latest-target recorder. Cover: key-down ignored; toggle key-up calls once; latest key-up with nil is inert; repeated presses reuse the same target; newer target wins; two consumers only; repeated start idempotent; stop cancels/awaits both consumers; event after stop ignored; blocked target lookup completing after stop ignored; restart accepts only new-generation events.

- [ ] **Step 2: Run RED**

Run `GlobalShortcutControllerTests`. Expected: missing controller.

- [ ] **Step 3: Implement generation-owned streams**

Use one task per action and key-up filtering:

```swift
@MainActor
final class GlobalShortcutController {
    private let registrar: any ShortcutRegistering
    private let latestTarget: any LatestNotificationTargetRecording
    private let toggleMenu: @MainActor () -> Void
    private let selectTarget: @MainActor (NotificationSelectionTarget) -> Void
    private var generation: UUID?
    private var tasks: [Task<Void, Never>] = []

    func start() {
        guard generation == nil else { return }
        let token = UUID()
        generation = token
        tasks = ShortcutAction.allCases.map { action in
            let events = registrar.events(for: action)
            return Task { [weak self] in
                for await event in events where event == .keyUp {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    await self.handle(action, token: token)
                }
            }
        }
    }
}
```

`handle(.focusLatestNotification)` awaits `latestTarget.latest()`, then revalidates the token before calling `selectTarget`. `stop()` invalidates the token first, cancels all tasks, awaits every value, and clears the array. Do not reset the latest target here; runtime teardown owns that ordering.

- [ ] **Step 4: Run GREEN and commit**

Run the focused suite 50 times and under Thread Sanitizer once.

```bash
git add HerdrMenubar/Shortcuts/GlobalShortcutController.swift HerdrMenubarTests/GlobalShortcutControllerTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: route global shortcut events"
```

---

### Task 6: Model the complete native status menu

**Files:**
- Create: `HerdrMenubar/Menu/StatusMenuPresentation.swift`
- Create: `HerdrMenubarTests/StatusMenuPresentationTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write exhaustive presentation RED tests**

Define expected node arrays for: searching, no sessions, connecting, connected idle, attention plus working sections, duplicate pane IDs in different sessions, unavailable sessions, transient error, terminal submenu including unavailable saved terminal, login toggle/help/error, notification/sound enablement/help/error, retry visibility, Keyboard Shortcuts, and Quit. Assert attention-first/session-second ordering and stable agent action identity.

- [ ] **Step 2: Run RED**

Run `StatusMenuPresentationTests`. Expected: missing snapshot/node/action types.

- [ ] **Step 3: Add immutable nodes and action identities**

Create these core types:

```swift
struct StatusItemPresentation: Equatable {
    let icon: MenuBarIconPresentation
    let accessibilityValue: String
    let menu: [StatusMenuNode]
}

enum MenuTextTone: Equatable { case secondary, error }

indirect enum StatusMenuNode: Equatable {
    case heading(String)
    case agent(title: String, subtitle: String, symbol: String, quieter: Bool,
               target: NotificationSelectionTarget)
    case info(String, tone: MenuTextTone)
    case toggle(title: String, isOn: Bool, isEnabled: Bool, action: StatusMenuAction)
    case submenu(title: String, children: [StatusMenuNode])
    case action(
        title: String,
        state: MenuItemState,
        isEnabled: Bool,
        action: StatusMenuAction
    )
    case separator
}

enum MenuItemState: Equatable { case off, on, mixed }

enum StatusMenuAction: Equatable {
    case select(NotificationSelectionTarget)
    case selectTerminal(String)
    case setLaunchAtLogin(Bool)
    case setNotifications(Bool)
    case setSound(Bool)
    case retryUnavailable
    case openKeyboardShortcuts
    case quit
}
```

Give `StatusMenuPresentationBuilder` this exact entry point:

```swift
func make(
    store: AgentStore,
    preferences: Preferences,
    terminals: [TerminalApp],
    loginItem: any LoginItemManaging,
    notifications: NotificationSettingsController
) -> StatusItemPresentation
```

It must reproduce every conditional branch in current `StatusMenu`, use `AgentMenuItem.visibleLabel`/`secondaryLabel`, map status symbols exactly as `AgentRow`, and append Keyboard Shortcuts immediately before the final separator/Quit block. Terminal choices are submenu actions with check state represented in the node; dynamic labels never become action identity.

- [ ] **Step 4: Run GREEN and commit**

Run `StatusMenuPresentationTests` and `MenuBarIconTests`.

```bash
git add HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubarTests/StatusMenuPresentationTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: model native status menu"
```

---

### Task 7: Own and toggle the AppKit status item safely

**Files:**
- Create: `HerdrMenubar/Menu/StatusItemController.swift`
- Create: `HerdrMenubarTests/StatusItemControllerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write driver-based RED tests**

Use `FakeStatusItemDriver` to prove: one item installed; icon/accessibility apply immediately; closed-menu snapshots rebuild immediately; tracked-menu snapshots only set dirty; `menuWillOpen` applies newest snapshot; `menuDidClose` applies changes received during tracking; closed toggle calls `performClick` once; open toggle calls `cancelTracking` once; mouse-open/shortcut-close and shortcut-open/mouse-dismiss reconcile; rapid toggles follow delegate callbacks, not inferred key count; every node maps to correct native action token.

- [ ] **Step 2: Run RED**

Run `StatusItemControllerTests`. Expected: controller/driver types absent.

- [ ] **Step 3: Implement driver and tracking policy**

Define a narrow main-actor driver:

```swift
@MainActor
protocol StatusItemDriving: AnyObject {
    func install(delegate: any StatusItemDriverDelegate)
    func applyIcon(_ presentation: MenuBarIconPresentation, accessibilityValue: String)
    func replaceMenu(with nodes: [StatusMenuNode], action: @escaping (StatusMenuAction) -> Void)
    func performClick()
    func cancelTracking()
    func remove()
}

@MainActor
protocol StatusItemDriverDelegate: AnyObject {
    func statusItemMenuWillOpen()
    func statusItemMenuDidClose()
}
```

`LiveStatusItemDriver` owns exactly one variable-length `NSStatusItem`, attaches one `NSMenu`, maps heading/info tone, symbol images, subtitles, toggle state, terminal submenu, enabled state, indentation, separators, and represented action tokens. Its `performClick()` must call `statusItem.button?.performClick(nil)`; never call deprecated `popUpStatusItemMenu`.

`StatusItemController` stores `isOpen`, `latest`, and `dirty`. Delegate callbacks alone set `isOpen`. `apply` always updates the icon; it rebuilds the menu only when closed. `menuWillOpen` applies latest before setting open; `menuDidClose` sets closed then applies dirty latest. `stop` cancels tracking, removes the status item, and ignores later snapshots.

- [ ] **Step 4: Run GREEN and commit**

Run focused tests 50 times. Run an ordinary Debug build to catch selector/`NSMenuItem` API errors.

```bash
git add HerdrMenubar/Menu/StatusItemController.swift HerdrMenubarTests/StatusItemControllerTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: control native status menu"
```

---

### Task 8: Add the reusable keyboard-shortcut settings window

**Files:**
- Create: `HerdrMenubar/Shortcuts/KeyboardShortcutSettingsView.swift`
- Create: `HerdrMenubar/Shortcuts/KeyboardShortcutSettingsWindowController.swift`
- Create: `HerdrMenubarTests/KeyboardShortcutSettingsTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write settings RED tests**

Test a pure row model for the two exact titles, initially unassigned values, independent clear enablement, display strings, inline per-action errors, and explanatory current-run target text. With a fake window driver, show twice must create once and order front twice; stop closes once; show after stop is ignored.

- [ ] **Step 2: Run RED**

Run `KeyboardShortcutSettingsTests`. Expected: settings types absent.

- [ ] **Step 3: Implement the view and window ownership**

The SwiftUI view must render exactly two rows:

```swift
ShortcutSettingsRow(title: "Toggle Herdr Menu", action: .toggleMenu)
ShortcutSettingsRow(title: "Focus Latest Notification", action: .focusLatestNotification)
Text("The latest notification shortcut uses notifications delivered during this app run.")
    .foregroundStyle(.secondary)
```

Each row contains `NativeShortcutRecorder`, an explicit Clear button, and red inline error. Capture calls `assign(binding,to:)`; Clear calls `assign(nil,to:)`. Give both recorders and clear buttons distinct accessibility labels.

`KeyboardShortcutSettingsWindowController` owns one `NSWindow`/`NSHostingController`, title `Keyboard Shortcuts`, non-resizable content sized to fit, standard close behavior, and `isReleasedWhenClosed = false`. Repeated `show()` calls `makeKeyAndOrderFront` on the same window and activates Herdr without changing its accessory/menu-bar policy.

- [ ] **Step 4: Run GREEN and commit**

Run assignment, recorder, and settings suites together.

```bash
git add HerdrMenubar/Shortcuts/KeyboardShortcutSettingsView.swift HerdrMenubar/Shortcuts/KeyboardShortcutSettingsWindowController.swift HerdrMenubarTests/KeyboardShortcutSettingsTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: configure global shortcuts"
```

---

### Task 9: Replace `MenuBarExtra` with an explicit application runtime

**Files:**
- Create: `HerdrMenubar/App/ApplicationRuntime.swift`
- Create: `HerdrMenubarTests/ApplicationRuntimeTests.swift`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift`
- Delete: `HerdrMenubar/Menu/StatusMenu.swift`
- Delete: `HerdrMenubar/Menu/AgentRow.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write runtime/delegate RED tests**

Use observable fake presentation state and gated lifecycle collaborators. Cover: `applicationDidFinishLaunching` starts once; shortcut consumers installed before store start; notification/login status refreshed before monitoring; observation immediately applies a snapshot and re-arms after each change; icon changes apply while menu tracking but structure defers; activation refreshes login/notification/shortcut registration; terminate replies later; shutdown order is invalidate → shortcut stop → menu/settings close → observation cancel → target reset → store stop; repeated terminate shares one stop; blocked start cannot resurrect after stop; late observation/shortcut callbacks are rejected.

- [ ] **Step 2: Run RED**

Run `ApplicationRuntimeTests`. Expected: missing runtime protocol/type and current delegate has no finish-launch hook.

- [ ] **Step 3: Compose the single live graph**

Create `@MainActor ApplicationRuntime` and move the current `HerdrMenubarApp.init` graph into `ApplicationRuntime.live()`. Construct exactly one each of `Preferences`, `NativeNotificationService`, `LatestNotificationTargetStore`, coordinator, notification settings, login item service, `AgentStore`, assignment controller, settings window, status item controller, and global shortcut controller. Inject the same latest-target store into coordinator and shortcut controller; inject `store.select(target)` into the shortcut controller.

Use this delegate-facing seam:

```swift
@MainActor
protocol ApplicationRuntimeServing: AnyObject {
    func start() async
    func applicationDidBecomeActive() async
    func stop() async
}
```

Map every `StatusMenuAction` without changing semantics:

```swift
case .select(let target): store.select(target)
case .selectTerminal(let id): preferences.selectedTerminalBundleIdentifier = id
case .setLaunchAtLogin(let enabled): Task { try? await updateLoginIntent(enabled) }
case .setNotifications(let enabled): Task { try? await notificationSettings.setNotificationsEnabled(enabled) }
case .setSound(let enabled): notificationSettings.setSoundEnabled(enabled)
case .retryUnavailable: Task { await store.retry() }
case .openKeyboardShortcuts: shortcutWindow.show()
case .quit: NSApplication.shared.terminate(nil)
```

Move `updateLoginIntent` from the deleted SwiftUI view to this runtime helper with its existing tested behavior:

```swift
private func updateLoginIntent(_ enabled: Bool) async throws {
    try await loginItemService.setEnabled(enabled)
    if enabled && (loginItemService.status == .enabled
        || loginItemService.status == .requiresApproval) {
        preferences.launchAtLoginIntent = true
    } else if !enabled, loginItemService.status == .disabled {
        preferences.launchAtLoginIntent = false
    }
}
```

- [ ] **Step 4: Add re-arming Observation**

Use a runtime generation and `withObservationTracking`:

```swift
private func observePresentation(generation: UUID) {
    guard owns(generation) else { return }
    let snapshot = withObservationTracking {
        presentationBuilder.make(
            store: store,
            preferences: preferences,
            terminals: installedTerminals,
            loginItem: loginItemService,
            notifications: notificationSettings
        )
    } onChange: { [weak self] in
        Task { @MainActor in self?.observePresentation(generation: generation) }
    }
    guard owns(generation) else { return }
    statusItem.apply(snapshot)
}
```

Stop changes the generation before any await, so queued re-arms cannot mutate stopped UI.

- [ ] **Step 5: Replace app lifecycle ownership**

`HerdrAppDelegate` strongly retains an `ApplicationRuntimeServing`, with an internal injectable initializer for tests. `applicationDidFinishLaunching` starts it, `applicationDidBecomeActive` refreshes it, and termination owns one async stop/reply. Replace the app body with:

```swift
@main
struct HerdrMenubarApp: App {
    @NSApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

Delete `StatusMenu.swift` and `AgentRow.swift` only after native parity tests pass, and remove their file/build references. Keep `MenuBarIcon.swift` for presentation/accessibility logic.

- [ ] **Step 6: Run GREEN, stress lifecycle, and commit**

Run `ApplicationRuntimeTests`, `StatusItemControllerTests`, `StatusMenuPresentationTests`, `AgentStoreTests`, and `SystemServiceTests`; stress blocked start/stop/restart 100 times. Run full non-UI suite and Debug build.

```bash
git add HerdrMenubar/App HerdrMenubar/Menu HerdrMenubarTests/ApplicationRuntimeTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: own menu and shortcuts in app runtime"
```

---

### Task 10: Prove two-session shortcut focus and release quality

**Files:**
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Add two-session accepted-delivery integration**

Extend the real two-socket fixture with a real `LatestNotificationTargetStore`, real coordinator, real `AgentStore`, and `GlobalShortcutController` over a fake registrar. Start default and named sessions with duplicate pane IDs. Deliver accepted attention for default, then named; send latest-notification key-up twice. Assert both presses focus only named and refresh named. Deliver a newer default notification; assert next key-up focuses only default. Hold named unavailable inside grace, press its latest shortcut, reconnect, and assert one exact named focus with no fallback.

Also send toggle-menu key-up through the same registrar into a fake status driver and assert open/close driver calls. This proves live controller wiring without touching the user's menu bar.

- [ ] **Step 2: Capture RED, then run stable GREEN**

Run only the new integration before completing any missing fake seams. Expected RED: a missing event injection or exact focus assertion. Make only fixture changes, then run the two integration scenarios five consecutive times. Assert no temporary sockets/processes remain.

- [ ] **Step 3: Update README precisely**

Document:

- Keyboard Shortcuts opens a small configuration window.
- Both actions are unassigned by default and persist independently after assignment.
- Toggle Herdr Menu opens and closes the native menu globally.
- Focus Latest Notification reuses the newest accepted notification target for the current run and may be pressed repeatedly.
- No current-run notification is a silent no-op; reconnect grace holds the exact target; removal has no fallback.
- No Accessibility or Input Monitoring permission is required.
- `KeyboardShortcuts` powers registration, but Herdr owns the macOS 26-compatible recorder.

Do not claim default assignments, persisted targets, per-agent shortcuts, fallback focus, SSH support, or notification behavior while notifications are disabled.

- [ ] **Step 4: Run final automated validation**

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -enableThreadSanitizer YES -only-testing:HerdrMenubarTests/GlobalShortcutControllerTests -only-testing:HerdrMenubarTests/ApplicationRuntimeTests
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
plutil -lint HerdrMenubar.xcodeproj/project.pbxproj HerdrMenubar/Info.plist HerdrMenubar/HerdrMenubar.entitlements
git diff --check
```

Expected: all tests, TSan, Release, Analyze, plist, and diff checks pass. Scan production logs and persistence for public session/pane/target/key text; expected none. Scan for `KeyboardShortcuts.Recorder`, `RecorderCocoa`, Accessibility APIs, event taps, and local event monitors; expected none.

- [ ] **Step 5: Install and perform the real macOS 26 smoke test**

Run `./scripts/install.sh`, verify bundle/signature/universal architectures, and launch normally. In Keyboard Shortcuts:

1. Confirm both fields begin unassigned on clean defaults.
2. Record, replace, and clear both using the native control; verify Escape cancels and the clear button works on macOS 26.6.1.
3. Assign temporary combinations and trigger each while another application is active.
4. Verify Toggle Herdr Menu opens, closes, and interoperates with mouse dismissal.
5. Trigger a real notification in each of two WezTerm/Herdr sessions; repeatedly press Focus Latest Notification and verify exact pane focus, then make the other notification newest and verify the target changes.
6. Disconnect/reconnect the target session inside grace and verify exact delayed focus without fallback.
7. Clear both shortcuts and prove they no longer fire.
8. Quit normally; verify no child process, listener task, temporary socket, or test artifact remains.

- [ ] **Step 6: Commit release coverage**

```bash
git add HerdrMenubarTests/MultiSessionIntegrationTests.swift README.md
git commit -m "test: verify global shortcuts end to end"
```

---

## Final self-review checklist

- [ ] Every goal, non-goal, race, privacy requirement, and success criterion in the design spec maps to a task above.
- [ ] `.accepted` is observable only after backend add; `.suppressed` and thrown delivery never replace the latest target.
- [ ] Per-submission ordinals pass the `a1`/`b1`/`a2` overlap and never let an older slow completion win.
- [ ] Notification clicks, latest-notification shortcut, and menu rows share exact latest-selection-wins store ownership.
- [ ] Shortcut target is reusable, current-run-only, held through grace, removed without fallback, and cleared on runtime teardown.
- [ ] Both shortcuts are unassigned initially, independently persistent, transactional on replacement, and inactive after clear.
- [ ] Native recorder is a first-responder control with no text field, package recorder, event monitor, event tap, Accessibility permission, or Input Monitoring permission.
- [ ] Native menu preserves all old content/actions and mutates structure only outside active tracking.
- [ ] Runtime owns launch, observation, shortcuts, menu/settings, target reset, and store stop in deterministic order.
- [ ] No dynamic session, pane, target, key event, or underlying error is logged publicly.
- [ ] No SSH transport, remote host UI, fallback focus, new terminal tab, default shortcut, or per-agent shortcut entered scope.
