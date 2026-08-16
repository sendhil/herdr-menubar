# Herdr Menubar Native Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in, silent-by-default native macOS notifications for every newly observed `blocked` or `done` transition, with clicks focusing the exact owning Herdr session and WezTerm pane.

**Architecture:** `AgentStore` forwards only lifecycle-accepted, fully labeled session snapshots to an actor-isolated `AttentionNotificationCoordinator`, which owns per-session transition history and delegates authorized delivery to a `NativeNotificationService`. A separate observable settings controller owns permission UI state, while notification default-action responses enter the store's existing latest-selection-wins focus pipeline and wait safely for launch-time discovery or grace-period reconnection.

**Tech Stack:** Swift 6, Swift concurrency actors and `Task`, Observation, SwiftUI `MenuBarExtra`, Apple `UserNotifications`, AppKit, XCTest, Xcode 26/macOS 26.

**Design spec:** `docs/superpowers/specs/2026-08-16-herdr-menubar-native-notifications-design.md`

---

## File map

| File | Responsibility |
| --- | --- |
| `HerdrMenubar/Notifications/NotificationModels.swift` | Notification target/event/settings value types and narrow service/coordinator protocols |
| `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift` | Per-session baseline, transition detection, reconnect retention, removal, and delivery decisions |
| `HerdrMenubar/Notifications/NativeNotificationService.swift` | `UNUserNotificationCenter` authorization, settings mapping, request construction, foreground policy, payload decoding, and response buffering |
| `HerdrMenubar/Notifications/NotificationSettingsController.swift` | Observable app-intent/system-permission state and serialized menu operations |
| `HerdrMenubar/System/Preferences.swift` | Persist Notifications and Sound intent, both defaulting off |
| `HerdrMenubar/Status/AgentStore.swift` | Forward accepted snapshots and route buffered notification targets through existing focus ownership |
| `HerdrMenubar/Menu/StatusMenu.swift` | Render Notifications and Sound toggles plus concise permission help |
| `HerdrMenubar/App/HerdrMenubarApp.swift` | Compose one live notification service/coordinator/controller and refresh settings on activation |
| `HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift` | Exhaustive transition, duplicate, multi-session, grace, removal, and disabled-baseline tests |
| `HerdrMenubarTests/NativeNotificationServiceTests.swift` | Authorization, content, sound, payload, foreground, malformed-response, and buffer tests |
| `HerdrMenubarTests/NotificationSettingsControllerTests.swift` | Defaults, persistence, permission success/denial/revocation, sound gating, busy, and error tests |
| `HerdrMenubarTests/AgentStoreTests.swift` | Accepted-snapshot forwarding, exact click routing, pending discovery/grace, supersession, and lifecycle races |
| `HerdrMenubarTests/MultiSessionIntegrationTests.swift` | Two-socket transition delivery and exact notification-click routing |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Add the Notifications group and new production/test sources to their targets |
| `README.md` | Describe notification triggers, defaults, click behavior, permissions, and privacy |

Use these currently unused Xcode IDs consistently:

```text
D20000000000000000000001  Notifications group
D20000000000000000000002  NotificationModels.swift file reference
D20000000000000000000003  NotificationModels.swift build file
D20000000000000000000004  AttentionNotificationCoordinator.swift file reference
D20000000000000000000005  AttentionNotificationCoordinator.swift build file
D20000000000000000000006  NativeNotificationService.swift file reference
D20000000000000000000007  NativeNotificationService.swift build file
D20000000000000000000008  NotificationSettingsController.swift file reference
D20000000000000000000009  NotificationSettingsController.swift build file
D2000000000000000000000A  AttentionNotificationCoordinatorTests.swift file reference
D2000000000000000000000B  AttentionNotificationCoordinatorTests.swift build file
D2000000000000000000000C  NativeNotificationServiceTests.swift file reference
D2000000000000000000000D  NativeNotificationServiceTests.swift build file
D2000000000000000000000E  NotificationSettingsControllerTests.swift file reference
D2000000000000000000000F  NotificationSettingsControllerTests.swift build file
```

Add the Notifications group to the main `HerdrMenubar` group. Add production build files to Sources phase `DC457981E1521EB96966F01E`; add test build files to Sources phase `E757C085039C0A48930F6D5E`.

## Shared test commands

Focused test command:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/<TestClass>
```

Complete non-UI suite:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

Xcode's DerivedData and test services require running these commands outside the filesystem sandbox in this workspace. Capture a genuine failing RED before adding each task's production implementation.

---

### Task 1: Add notification domain models and persisted intent

**Files:**
- Create: `HerdrMenubar/Notifications/NotificationModels.swift`
- Modify: `HerdrMenubar/System/Preferences.swift`
- Modify: `HerdrMenubarTests/PreferencesTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing preference tests**

Add these cases to `PreferencesTests`:

```swift
func testNotificationPreferencesDefaultOff() {
    withDefaults { defaults in
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.notificationsEnabled)
        XCTAssertFalse(preferences.notificationSoundEnabled)
    }
}

func testNotificationPreferencesPersistIndependently() {
    withDefaults { defaults in
        let preferences = Preferences(defaults: defaults)
        preferences.notificationsEnabled = true
        preferences.notificationSoundEnabled = true

        let restored = Preferences(defaults: defaults)
        XCTAssertTrue(restored.notificationsEnabled)
        XCTAssertTrue(restored.notificationSoundEnabled)
        XCTAssertTrue(defaults.bool(forKey: Preferences.notificationsEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: Preferences.notificationSoundEnabledKey))

        restored.notificationsEnabled = false
        XCTAssertFalse(Preferences(defaults: defaults).notificationsEnabled)
        XCTAssertTrue(Preferences(defaults: defaults).notificationSoundEnabled)
    }
}
```

- [ ] **Step 2: Run `PreferencesTests` and record RED**

Run the focused command with `PreferencesTests`.

Expected: compilation fails because both notification properties and keys are absent.

- [ ] **Step 3: Add the two persisted preferences**

Add to `Preferences`:

```swift
static let notificationsEnabledKey = "notificationsEnabled"
static let notificationSoundEnabledKey = "notificationSoundEnabled"

var notificationsEnabled: Bool {
    didSet { defaults.set(notificationsEnabled, forKey: Self.notificationsEnabledKey) }
}

var notificationSoundEnabled: Bool {
    didSet { defaults.set(notificationSoundEnabled, forKey: Self.notificationSoundEnabledKey) }
}
```

Initialize both after `launchAtLoginIntent`:

```swift
notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
notificationSoundEnabled = defaults.bool(forKey: Self.notificationSoundEnabledKey)
```

- [ ] **Step 4: Add the shared notification types and protocols**

Create `NotificationModels.swift` with:

```swift
import Foundation

struct NotificationSelectionTarget: Equatable, Sendable {
    let sessionID: SessionID
    let paneID: String
}

struct AttentionNotificationEvent: Equatable, Sendable {
    let target: NotificationSelectionTarget
    let sessionName: String
    let visibleLabel: String
    let status: AgentStatus
}

struct NotificationDeliveryPolicy: Equatable, Sendable {
    let notificationsEnabled: Bool
    let soundEnabled: Bool
}

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

struct NotificationSystemSettings: Equatable, Sendable {
    let authorization: NotificationAuthorization
    let alertsEnabled: Bool
    let soundsEnabled: Bool

    static let notDetermined = NotificationSystemSettings(
        authorization: .notDetermined,
        alertsEnabled: false,
        soundsEnabled: false
    )
    static let authorized = NotificationSystemSettings(
        authorization: .authorized,
        alertsEnabled: true,
        soundsEnabled: true
    )
    static let denied = NotificationSystemSettings(
        authorization: .denied,
        alertsEnabled: false,
        soundsEnabled: false
    )
}

protocol NativeNotificationServing: Sendable {
    func responses() async -> AsyncStream<NotificationSelectionTarget>
    func requestAuthorization() async throws -> Bool
    func settings() async -> NotificationSystemSettings
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws
}

protocol AttentionNotificationCoordinating: Sendable {
    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) async
    func unavailable(sessionID: SessionID) async
    func remove(sessionID: SessionID) async
    func reset() async
}
```

- [ ] **Step 5: Add `NotificationModels.swift` to the project and run GREEN**

Add IDs `D2...001` through `D2...003` to the project, group, and production Sources phase. Run `PreferencesTests`, `plutil -lint HerdrMenubar.xcodeproj/project.pbxproj`, and `xcodebuild -list -project HerdrMenubar.xcodeproj`.

Expected: preference tests pass; project parsing succeeds.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Notifications/NotificationModels.swift HerdrMenubar/System/Preferences.swift HerdrMenubarTests/PreferencesTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: model notification preferences"
```

---

### Task 2: Detect attention transitions without startup or reconnect floods

**Files:**
- Create: `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift`
- Create: `HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing coordinator matrix**

Create `AttentionNotificationCoordinatorTests.swift`. Use this test shape and keep every assertion explicit:

```swift
import XCTest
@testable import HerdrMenubar

final class AttentionNotificationCoordinatorTests: XCTestCase {
    func testFirstSnapshotIsSilentAndLaterDistinctAttentionTransitionsDeliverOnce() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false)

        await coordinator.reconcile(
            session: session,
            items: [item(session, "p", .done)],
            policy: policy
        )
        XCTAssertEqual(await service.deliveries, [])

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)

        XCTAssertEqual(await service.deliveries.map(\.event.status), [.blocked, .done, .blocked])
        XCTAssertEqual(await service.deliveries.map(\.sound), [false, false, false])
    }

    func testNewAttentionPaneInBaselinedSessionDeliversButInitialSessionDoesNot() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: true)

        await coordinator.reconcile(session: session, items: [item(session, "a", .working)], policy: policy)
        await coordinator.reconcile(
            session: session,
            items: [item(session, "a", .working), item(session, "b", .done)],
            policy: policy
        )

        XCTAssertEqual(await service.deliveries.map(\.event.target.paneID), ["b"])
        XCTAssertEqual(await service.deliveries.map(\.sound), [true])
    }

    func testDuplicatePaneIDsAreIndependentAcrossSessions() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let defaultSession = SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/default.sock"))
        let work = descriptor("work")
        let policy = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false)

        await coordinator.reconcile(session: defaultSession, items: [item(defaultSession, "same", .working)], policy: policy)
        await coordinator.reconcile(session: work, items: [item(work, "same", .working)], policy: policy)
        await coordinator.reconcile(session: work, items: [item(work, "same", .blocked)], policy: policy)

        XCTAssertEqual(await service.deliveries.map(\.event.target), [
            NotificationSelectionTarget(sessionID: .named("work"), paneID: "same")
        ])
    }

    func testUnavailableRetainsHistoryRemovalClearsItAndRecreatedSessionPrimesSilently() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let policy = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: false)

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: policy)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.unavailable(sessionID: session.id)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: policy)
        await coordinator.remove(sessionID: session.id)
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: policy)

        XCTAssertEqual(await service.deliveries.map(\.event.status), [.blocked])
    }

    func testDisabledDeliveryStillAdvancesBaselineAndResetMakesNextSnapshotSilent() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(service: service)
        let session = descriptor("work")
        let off = NotificationDeliveryPolicy(notificationsEnabled: false, soundEnabled: true)
        let on = NotificationDeliveryPolicy(notificationsEnabled: true, soundEnabled: true)

        await coordinator.reconcile(session: session, items: [item(session, "p", .working)], policy: off)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: off)
        await coordinator.reconcile(session: session, items: [item(session, "p", .blocked)], policy: on)
        await coordinator.reset()
        await coordinator.reconcile(session: session, items: [item(session, "p", .done)], policy: on)

        XCTAssertEqual(await service.deliveries, [])
    }
}

private actor RecordingNotificationService: NativeNotificationServing {
    struct Delivery: Equatable { let event: AttentionNotificationEvent; let sound: Bool }
    private(set) var deliveries: [Delivery] = []
    func responses() -> AsyncStream<NotificationSelectionTarget> { AsyncStream { $0.finish() } }
    func requestAuthorization() -> Bool { true }
    func settings() -> NotificationSystemSettings {
        NotificationSystemSettings(authorization: .authorized, alertsEnabled: true, soundsEnabled: true)
    }
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) {
        deliveries.append(Delivery(event: event, sound: sound))
    }
}
```

Add helpers that construct a real `SessionDescriptor`, `PaneInfo`, and `AgentMenuItem`; include a disappearance/reappearance test that removes `p` from one authoritative snapshot and expects a later blocked `p` to deliver once.

- [ ] **Step 2: Add the test file to the project and record RED**

Add IDs `D2...00A` and `D2...00B`. Run the focused command with `AttentionNotificationCoordinatorTests`.

Expected: compilation fails because `AttentionNotificationCoordinator` does not exist.

- [ ] **Step 3: Implement the actor-isolated coordinator**

Create `AttentionNotificationCoordinator.swift`:

```swift
import OSLog

actor AttentionNotificationCoordinator: AttentionNotificationCoordinating {
    private let service: any NativeNotificationServing
    private var baselinedSessions: Set<SessionID> = []
    private var statuses: [SessionID: [String: AgentStatus]] = [:]

    init(service: any NativeNotificationServing) {
        self.service = service
    }

    func reconcile(
        session: SessionDescriptor,
        items: [AgentMenuItem],
        policy: NotificationDeliveryPolicy
    ) async {
        let current = Dictionary(uniqueKeysWithValues: items.map { ($0.paneID, $0.status) })
        guard baselinedSessions.contains(session.id) else {
            baselinedSessions.insert(session.id)
            statuses[session.id] = current
            return
        }

        let previous = statuses[session.id] ?? [:]
        statuses[session.id] = current
        guard policy.notificationsEnabled else { return }

        for item in items.sorted(by: AgentMenuItem.labelOrder) {
            guard item.status == .blocked || item.status == .done else { continue }
            guard previous[item.paneID] != item.status else { continue }
            do {
                try await service.deliver(
                    AttentionNotificationEvent(
                        target: NotificationSelectionTarget(
                            sessionID: session.id,
                            paneID: item.paneID
                        ),
                        sessionName: session.displayName,
                        visibleLabel: item.visibleLabel,
                        status: item.status
                    ),
                    sound: policy.soundEnabled
                )
            } catch {
                AppLog.systemActions.error(
                    "Notification delivery failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func unavailable(sessionID: SessionID) {
        // Preserve the last authoritative status through the supervisor's grace period.
    }

    func remove(sessionID: SessionID) {
        baselinedSessions.remove(sessionID)
        statuses.removeValue(forKey: sessionID)
    }

    func reset() {
        baselinedSessions.removeAll()
        statuses.removeAll()
    }
}
```

The `previous[item.paneID] != item.status` rule intentionally covers new panes, non-attention to attention, `blocked → done`, and `done → blocked`; same-status snapshots remain silent.

- [ ] **Step 4: Add production project entries and run GREEN repeatedly**

Add IDs `D2...004` and `D2...005`. Run the focused suite once, then 20 iterations of the test binary's coordinator suite.

Expected: all coordinator cases pass every iteration; `git diff --check` is clean.

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: detect agent attention transitions"
```

---

### Task 3: Wrap native macOS notifications and buffer click responses

**Files:**
- Create: `HerdrMenubar/Notifications/NativeNotificationService.swift`
- Create: `HerdrMenubarTests/NativeNotificationServiceTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing authorization and request-content tests**

Create `NativeNotificationServiceTests.swift` with a lock-protected `FakeNotificationCenterBackend`. Add these tests:

```swift
func testAuthorizationRequestsAlertsAndSoundExactly() async throws {
    let backend = FakeNotificationCenterBackend(authorizationResult: true)
    let service = NativeNotificationService(backend: backend)

    XCTAssertTrue(try await service.requestAuthorization())
    XCTAssertEqual(backend.requestedOptions, [.alert, .sound])
}

func testDeliveryBuildsUniqueSilentRequestWithVersionedExactTarget() async throws {
    let backend = FakeNotificationCenterBackend(settings: .authorized)
    let service = NativeNotificationService(backend: backend)
    let event = AttentionNotificationEvent(
        target: NotificationSelectionTarget(sessionID: .named("work"), paneID: "pane-1"),
        sessionName: "work",
        visibleLabel: "Herdr Menubar · server",
        status: .done
    )

    try await service.deliver(event, sound: false)
    try await service.deliver(event, sound: false)

    let requests = backend.addedRequests
    XCTAssertEqual(requests.count, 2)
    XCTAssertNotEqual(requests[0].identifier, requests[1].identifier)
    XCTAssertEqual(requests[0].content.title, "Agent finished")
    XCTAssertEqual(requests[0].content.body, "Herdr Menubar · server — work")
    XCTAssertNil(requests[0].content.sound)
    XCTAssertNil(requests[0].trigger)
    XCTAssertEqual(requests[0].content.userInfo["version"] as? Int, 1)
    XCTAssertEqual(requests[0].content.userInfo["session_kind"] as? String, "named")
    XCTAssertEqual(requests[0].content.userInfo["session_name"] as? String, "work")
    XCTAssertEqual(requests[0].content.userInfo["pane_id"] as? String, "pane-1")
}

func testSoundRequiresRequestedSoundAndEnabledSystemSound() async throws {
    let backend = FakeNotificationCenterBackend(settings: .authorized)
    let service = NativeNotificationService(backend: backend)
    let event = blockedEvent()

    try await service.deliver(event, sound: true)
    XCTAssertNotNil(backend.addedRequests[0].content.sound)

    backend.settingsValue = NotificationSystemSettings(
        authorization: .authorized,
        alertsEnabled: true,
        soundsEnabled: false
    )
    try await service.deliver(event, sound: true)
    XCTAssertNil(backend.addedRequests.last?.content.sound)
}

func testUnauthorizedOrAlertDisabledDeliveryAddsNothing() async throws {
    for settings in [
        NotificationSystemSettings(authorization: .denied, alertsEnabled: true, soundsEnabled: true),
        NotificationSystemSettings(authorization: .authorized, alertsEnabled: false, soundsEnabled: true)
    ] {
        let backend = FakeNotificationCenterBackend(settings: settings)
        let service = NativeNotificationService(backend: backend)
        try await service.deliver(blockedEvent(), sound: true)
        XCTAssertEqual(backend.addedRequests, [])
    }
}
```

- [ ] **Step 2: Write failing payload, buffer, and foreground-policy tests**

Add:

```swift
func testDefaultActionDecodesBeforeSubscriberAndMalformedActionsAreIgnored() async {
    let backend = FakeNotificationCenterBackend(settings: .authorized)
    let service = NativeNotificationService(backend: backend)

    service.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [
        "version": 1,
        "session_kind": "default",
        "pane_id": "p"
    ])
    service.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: [
        "version": 1, "session_kind": "named", "session_name": "ignored", "pane_id": "x"
    ])
    service.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [
        "version": 2, "session_kind": "default", "pane_id": "future"
    ])

    var iterator = await service.responses().makeAsyncIterator()
    XCTAssertEqual(
        await iterator.next(),
        NotificationSelectionTarget(sessionID: .default, paneID: "p")
    )
    XCTAssertEqual(NativeNotificationService.foregroundPresentationOptions, [.list])
}
```

- [ ] **Step 3: Add test file project entries and record RED**

Add IDs `D2...00C` and `D2...00D`. Run `NativeNotificationServiceTests`.

Expected: compilation fails because the service and backend seam do not exist.

- [ ] **Step 4: Implement the live service and backend**

Create `NativeNotificationService.swift` with these concrete seams and behaviors:

```swift
import Foundation
import UserNotifications

protocol UserNotificationCenterBacking: Sendable {
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func settings() async -> NotificationSystemSettings
    func add(_ request: UNNotificationRequest) async throws
}

final class LiveUserNotificationCenterBackend: UserNotificationCenterBacking, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) { center.delegate = delegate }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }
    func settings() async -> NotificationSystemSettings {
        let value = await center.notificationSettings()
        let authorization: NotificationAuthorization
        switch value.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .authorized, .provisional, .ephemeral: authorization = .authorized
        case .denied: authorization = .denied
        @unknown default: authorization = .denied
        }
        return NotificationSystemSettings(
            authorization: authorization,
            alertsEnabled: value.alertSetting == .enabled,
            soundsEnabled: value.soundSetting == .enabled
        )
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

final class NativeNotificationService: NSObject, NativeNotificationServing,
    UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.list]
    private let backend: any UserNotificationCenterBacking
    private let responseStream: AsyncStream<NotificationSelectionTarget>
    private let responseContinuation: AsyncStream<NotificationSelectionTarget>.Continuation

    init(backend: any UserNotificationCenterBacking = LiveUserNotificationCenterBackend()) {
        self.backend = backend
        (responseStream, responseContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        super.init()
        backend.setDelegate(self)
    }

    func responses() -> AsyncStream<NotificationSelectionTarget> { responseStream }
    func requestAuthorization() async throws -> Bool {
        try await backend.requestAuthorization(options: [.alert, .sound])
    }
    func settings() async -> NotificationSystemSettings { await backend.settings() }

    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws {
        let settings = await backend.settings()
        guard settings.authorization == .authorized, settings.alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = event.status == .blocked ? "Agent blocked" : "Agent finished"
        content.body = "\(event.visibleLabel) — \(event.sessionName)"
        if sound && settings.soundsEnabled { content.sound = .default }
        content.userInfo = Self.payload(for: event.target)
        try await backend.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        handleResponse(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
    }

    func handleResponse(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = Self.decodeTarget(userInfo) else { return }
        responseContinuation.yield(target)
    }
}
```

Implement `payload(for:)` and `decodeTarget(_:)` with version `1`, `session_kind` values `default`/`named`, a required nonempty `session_name` for named sessions, and a required nonempty `pane_id`. Do not log rejected payload values.

- [ ] **Step 5: Add production project entries and run GREEN**

Add IDs `D2...006` and `D2...007`. Run `NativeNotificationServiceTests` three times and `AttentionNotificationCoordinatorTests` once.

Expected: all pass; each fake backend sees its delegate installed exactly once.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Notifications/NativeNotificationService.swift HerdrMenubarTests/NativeNotificationServiceTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: deliver native macos notifications"
```

---

### Task 4: Add serialized permission and sound settings state

**Files:**
- Create: `HerdrMenubar/Notifications/NotificationSettingsController.swift`
- Create: `HerdrMenubarTests/NotificationSettingsControllerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing controller tests**

Create `NotificationSettingsControllerTests.swift` and cover these exact cases with an actor-backed fake service and isolated `UserDefaults`:

```swift
func testEnablePersistsOnlyAfterGrantedAuthorization() async throws {
    let fixture = fixture(authorizationResult: true, settings: .authorized)
    try await fixture.controller.setNotificationsEnabled(true)
    XCTAssertTrue(fixture.preferences.notificationsEnabled)
    XCTAssertEqual(await fixture.service.authorizationRequests, 1)
    XCTAssertEqual(fixture.controller.systemSettings.authorization, .authorized)
}

func testDenialLeavesIntentOffAndShowsSystemSettingsHelp() async throws {
    let denied = NotificationSystemSettings(
        authorization: .denied, alertsEnabled: false, soundsEnabled: false
    )
    let fixture = fixture(authorizationResult: false, settings: denied)
    try await fixture.controller.setNotificationsEnabled(true)
    XCTAssertFalse(fixture.preferences.notificationsEnabled)
    XCTAssertEqual(fixture.controller.helpText, "Allow notifications in System Settings")
}

func testExternalRevocationPreservesIntentAndRefreshShowsHelp() async {
    let fixture = fixture(authorizationResult: true, settings: .authorized)
    fixture.preferences.notificationsEnabled = true
    await fixture.service.setSettings(.denied)
    await fixture.controller.refreshStatus()
    XCTAssertTrue(fixture.controller.isEnabled)
    XCTAssertEqual(fixture.controller.helpText, "Notifications are disabled in System Settings")
}

func testSoundPersistsButIsEffectiveOnlyWhenNotificationsAreOn() {
    let fixture = fixture(authorizationResult: true, settings: .authorized)
    fixture.controller.setSoundEnabled(true)
    XCTAssertTrue(fixture.preferences.notificationSoundEnabled)
    XCTAssertFalse(fixture.controller.canEnableSound)
    fixture.preferences.notificationsEnabled = true
    XCTAssertTrue(fixture.controller.canEnableSound)
}
```

Also add a gated authorization test: start one `setNotificationsEnabled(true)`, wait until `isChanging`, assert a second call throws `NotificationSettingsOperationError.busy`, release the first, and prove exactly one authorization request occurred. Add an authorization-error case that leaves intent off, sets `errorMessage` to `Could not enable notifications.`, keeps `isChanging == false`, and logs no public dynamic values.

- [ ] **Step 2: Add test project entries and record RED**

Add IDs `D2...00E` and `D2...00F`. Run `NotificationSettingsControllerTests`.

Expected: compilation fails because the controller and typed busy error do not exist.

- [ ] **Step 3: Implement the observable controller**

Create `NotificationSettingsController.swift`:

```swift
import Observation
import OSLog

enum NotificationSettingsOperationError: Error, Equatable { case busy }

@Observable @MainActor
final class NotificationSettingsController {
    private let service: any NativeNotificationServing
    private let preferences: Preferences
    private(set) var systemSettings: NotificationSystemSettings = .notDetermined
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    var isEnabled: Bool { preferences.notificationsEnabled }
    var isSoundEnabled: Bool { preferences.notificationSoundEnabled }
    var canEnableSound: Bool { preferences.notificationsEnabled && !isChanging }
    var helpText: String? {
        if systemSettings.authorization == .denied {
            return preferences.notificationsEnabled
                ? "Notifications are disabled in System Settings"
                : "Allow notifications in System Settings"
        }
        if preferences.notificationSoundEnabled && !systemSettings.soundsEnabled {
            return "Notification sounds are disabled in System Settings"
        }
        return nil
    }

    init(service: any NativeNotificationServing, preferences: Preferences) {
        self.service = service
        self.preferences = preferences
    }

    func refreshStatus() async {
        systemSettings = await service.settings()
    }

    func setNotificationsEnabled(_ enabled: Bool) async throws {
        guard !isChanging else { throw NotificationSettingsOperationError.busy }
        if !enabled {
            preferences.notificationsEnabled = false
            errorMessage = nil
            return
        }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false }
        do {
            let granted = try await service.requestAuthorization()
            systemSettings = await service.settings()
            preferences.notificationsEnabled = granted
                && systemSettings.authorization == .authorized
        } catch {
            preferences.notificationsEnabled = false
            errorMessage = "Could not enable notifications."
            AppLog.systemActions.error(
                "Notification authorization failed: \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    func setSoundEnabled(_ enabled: Bool) {
        preferences.notificationSoundEnabled = enabled
    }
}
```

- [ ] **Step 4: Add production project entries and run GREEN repeatedly**

Add IDs `D2...008` and `D2...009`. Run the focused suite once, then repeat the busy/error cases 20 times.

Expected: every run passes and no async operation remains blocked.

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/Notifications/NotificationSettingsController.swift HerdrMenubarTests/NotificationSettingsControllerTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: manage notification permission settings"
```

---

### Task 5: Feed accepted snapshots to notifications and route exact clicks

**Files:**
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`

- [ ] **Step 1: Write failing snapshot-forwarding tests**

Extend the `AgentStoreTests.makeStore` helper to accept required `attentionCoordinator` and `notificationService` fakes. Add tests proving:

```swift
func testOnlyAcceptedFullSnapshotsReachNotificationCoordinator() async {
    let supervisor = FakeSessionSupervisor()
    let coordinator = RecordingAttentionCoordinator()
    let notifications = RecordingNotificationService()
    let preferences = testPreferences()
    preferences.notificationsEnabled = true
    let store = makeStore(
        supervisor: supervisor,
        attentionCoordinator: coordinator,
        notificationService: notifications,
        preferences: preferences
    )
    await store.start()

    await supervisor.send(.connected(workDescriptor, snapshot([
        pane("idle", .idle), pane("blocked", .blocked)
    ])))
    await waitUntil { await coordinator.reconciliations.count == 1 }
    let call = await coordinator.reconciliations[0]
    XCTAssertEqual(call.session.id, .named("work"))
    XCTAssertEqual(Set(call.items.map(\.paneID)), ["idle", "blocked"])
    XCTAssertEqual(call.policy, NotificationDeliveryPolicy(
        notificationsEnabled: true,
        soundEnabled: false
    ))

    await store.stop()
    await supervisor.send(.snapshot(.named("work"), snapshot([pane("late", .done)])))
    XCTAssertEqual(await coordinator.reconciliations.count, 1)
    XCTAssertEqual(await coordinator.resetCount, 1)
}
```

Add separate assertions that `.unavailable` calls `coordinator.unavailable` without clearing history and `.removed` calls both `coordinator.remove` and the existing WezTerm `forget` exactly once.

- [ ] **Step 2: Write failing click lifecycle tests**

Add a `RecordingNotificationService` whose `responses()` stream is created before `store.start()`. Add these deterministic cases:

```swift
func testBufferedNotificationClickWaitsForConnectionThenUsesExactSelectionFlow() async {
    let sequence = ActionSequence()
    let supervisor = FakeSessionSupervisor(sequence: sequence)
    let notifications = RecordingNotificationService()
    let store = makeStore(
        supervisor: supervisor,
        terminalActivator: RecordingActivator(sequence: sequence),
        wezTermFocuser: RecordingWezTermFocuser(sequence: sequence),
        notificationService: notifications
    )
    await notifications.send(NotificationSelectionTarget(sessionID: .named("work"), paneID: "p"))
    await store.start()
    await supervisor.send(.discoverySnapshot([workDescriptor]))
    XCTAssertEqual(await supervisor.focusRequests, [])

    await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .done)])))
    await waitUntil { await supervisor.focusRequests.count == 1 }
    XCTAssertEqual(await supervisor.focusRequests, [
        FocusRequest(sessionID: .named("work"), paneID: "p")
    ])
    XCTAssertEqual(await sequence.values, [
        "focus:work:p", "wezterm:work", "activate:com.github.wez.wezterm", "refresh:work"
    ])
}
```

Add cases where the target remains pending across `.unavailable`, is discarded on `.removed`, is discarded when a completed discovery snapshot omits its session, and is cleared by `stop()`. Add a latest-wins test where a blocked first notification selection is canceled by a menu selection for another session and only the newer selection activates.

- [ ] **Step 3: Run `AgentStoreTests` and record RED**

Expected: compilation fails because `AgentStore` does not accept notification dependencies or consume targets.

- [ ] **Step 4: Refactor item construction without changing menu output**

Change `makeItems` into a full-item builder plus filtering:

```swift
func makeAllItems(snapshot: PresentationSnapshot, session: SessionDescriptor) -> [AgentMenuItem] {
    let workspacesByID = Dictionary(
        uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) }
    )
    let tabsByID = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })
    var tabIDsByWorkspace: [String: Set<String>] = [:]
    for tab in snapshot.tabs {
        tabIDsByWorkspace[tab.workspaceID, default: []].insert(tab.tabID)
    }
    for pane in snapshot.panes {
        tabIDsByWorkspace[pane.workspaceID, default: []].insert(pane.tabID)
    }
    return snapshot.panes.map { pane in
        let workspace = workspacesByID[pane.workspaceID]
        let isMultiTab = (workspace?.tabCount ?? 0) > 1
            || (tabIDsByWorkspace[pane.workspaceID]?.count ?? 0) > 1
        return AgentMenuItem(
            session: session,
            pane: pane,
            workspace: workspace,
            tab: tabsByID[pane.tabID],
            workspaceIsMultiTab: isMultiTab
        )
    }
}

func makePresentationItems(
    _ items: [AgentMenuItem]
) -> (attention: [AgentMenuItem], working: [AgentMenuItem]) {
    (
        items.filter { $0.status == .blocked || $0.status == .done }
            .sorted(by: AgentMenuItem.attentionOrder),
        items.filter { $0.status == .working }
            .sorted(by: AgentMenuItem.labelOrder)
    )
}
```

For each accepted connected/snapshot event, build all items once, update the existing menu arrays, derive connection state, then `await attentionCoordinator.reconcile` with the current preference policy. Convert `consume` to `async` and await it from the supervisor event loop so reconciliation ordering matches authoritative snapshot ordering.

- [ ] **Step 5: Generalize selection around a stable target**

Add:

```swift
private struct AgentSelectionTarget: Sendable {
    let sessionID: SessionID
    let paneID: String
    let sessionName: String
}

func select(_ item: AgentMenuItem) async {
    await startSelection(AgentSelectionTarget(
        sessionID: item.sessionID,
        paneID: item.paneID,
        sessionName: item.sessionName
    ))?.value
}

@discardableResult
func startSelection(_ target: AgentSelectionTarget) -> Task<Void, Never>? {
    guard stopTask == nil else { return nil }
    let generation = UUID()
    selectionGeneration = generation
    transientError = nil
    let predecessor = selectionTask
    predecessor?.cancel()
    let task = Task { [weak self] in
        await predecessor?.value
        guard let self, self.ownsSelection(generation) else { return }
        await self.performSelection(target, generation: generation)
        if self.selectionGeneration == generation {
            self.selectionTask = nil
        }
    }
    selectionTask = task
    return task
}
```

Change `performSelection` to accept `AgentSelectionTarget`; its full body is:

```swift
func performSelection(_ target: AgentSelectionTarget, generation: UUID) async {
    do {
        _ = try await supervisor.focus(
            sessionID: target.sessionID,
            paneID: target.paneID
        )
    } catch {
        AppLog.systemActions.error(
            "Pane focus failed: \(error.localizedDescription, privacy: .private)"
        )
        if ownsSelection(generation) {
            transientError = "Could not focus pane in \(target.sessionName): \(error.localizedDescription)"
        }
        return
    }
    guard ownsSelection(generation) else {
        await supervisor.refresh(sessionID: target.sessionID)
        return
    }
    let bundleIdentifier = preferences.selectedTerminalBundleIdentifier
    if bundleIdentifier == WezTermCLIConstants.bundleIdentifier {
        do {
            try await wezTermFocuser.focusAttachedClient(sessionID: target.sessionID)
        } catch {
            AppLog.systemActions.error(
                "WezTerm session focus failed: \(error.localizedDescription, privacy: .private)"
            )
            if ownsSelection(generation) {
                transientError = wezTermFocusMessage(error, sessionName: target.sessionName)
            }
            await supervisor.refresh(sessionID: target.sessionID)
            return
        }
    }
    if ownsSelection(generation) {
        do {
            try await terminalActivator.activate(bundleIdentifier: bundleIdentifier)
        } catch {
            AppLog.systemActions.error(
                "Terminal activation failed: \(error.localizedDescription, privacy: .private)"
            )
            if ownsSelection(generation) { transientError = error.localizedDescription }
        }
    }
    await supervisor.refresh(sessionID: target.sessionID)
}
```

- [ ] **Step 6: Own the notification response consumer and one pending target**

Add required initializer properties `attentionCoordinator` and `notificationService`, plus:

```swift
private var notificationResponseTask: Task<Void, Never>?
private var pendingNotificationTarget: NotificationSelectionTarget?
```

During `start`, acquire `await notificationService.responses()` after the supervisor stream and revalidate the same start token after both suspensions. Install a response task before calling `supervisor.start()`:

```swift
notificationResponseTask = Task { [weak self] in
    for await target in notificationResponses {
        guard !Task.isCancelled else { return }
        await self?.receiveNotificationTarget(target, generation: generation)
    }
}
```

Implement response ownership with:

```swift
func receiveNotificationTarget(
    _ target: NotificationSelectionTarget,
    generation: UUID
) {
    guard isRunning, eventGeneration == generation else { return }
    guard let state = sessions[target.sessionID] else {
        if hasCompletedDiscovery {
            pendingNotificationTarget = nil
            transientError = "\(target.sessionID.displayName) is unavailable"
        } else {
            pendingNotificationTarget = target
        }
        return
    }
    guard state.isConnected else {
        pendingNotificationTarget = target
        return
    }
    pendingNotificationTarget = nil
    startSelection(AgentSelectionTarget(
        sessionID: target.sessionID,
        paneID: target.paneID,
        sessionName: state.descriptor.displayName
    ))
}

func discardAbsentPendingTarget(discovered: [SessionDescriptor]) {
    guard let pendingNotificationTarget,
          !discovered.contains(where: { $0.id == pendingNotificationTarget.sessionID }) else {
        return
    }
    self.pendingNotificationTarget = nil
    transientError = "\(pendingNotificationTarget.sessionID.displayName) is unavailable"
}
```

On `.connected`, call `receiveNotificationTarget` for a matching pending target after storing the connected state. On `.discoverySnapshot`, call `discardAbsentPendingTarget` after recording the descriptors. On matching `.removed`, clear the target; `.unavailable` retains it.

At stop initiation, capture and nil `notificationResponseTask`, clear `pendingNotificationTarget`, cancel the response task, and add `await responseConsumer?.value` before `await attentionCoordinator.reset()` and `await supervisor.stop()`. This keeps shutdown ordered and prevents an old consumer from handing a response to a restarted store.

- [ ] **Step 7: Run GREEN and stress lifecycle cases**

Run `AgentStoreTests`, `AttentionNotificationCoordinatorTests`, and the current `MultiSessionIntegrationTests`. Repeat the buffered-launch, reconnect/removal, latest-wins, and stop/restart cases 50 times.

Expected: no failures, hangs, late focus, duplicate focus, or Swift 6 isolation diagnostics.

- [ ] **Step 8: Commit**

```bash
git add HerdrMenubar/Status/AgentStore.swift HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/MultiSessionIntegrationTests.swift
git commit -m "feat: route notification state and selections"
```

---

### Task 6: Add menu controls and live app composition

**Files:**
- Modify: `HerdrMenubar/Menu/StatusMenu.swift`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift`
- Modify: `HerdrMenubarTests/NotificationSettingsControllerTests.swift`
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`

- [ ] **Step 1: Strengthen controller tests for menu bindings**

Add assertions that disabling notifications persists off without calling authorization, Sound remains persisted but `canEnableSound` becomes false, and a later refresh after System Settings reauthorization clears help without rewriting app intent:

```swift
func testDisableDoesNotRequestAuthorizationOrEraseSoundPreference() async throws {
    let fixture = fixture(authorizationResult: true, settings: .authorized)
    fixture.preferences.notificationsEnabled = true
    fixture.preferences.notificationSoundEnabled = true

    try await fixture.controller.setNotificationsEnabled(false)

    XCTAssertFalse(fixture.controller.isEnabled)
    XCTAssertTrue(fixture.controller.isSoundEnabled)
    XCTAssertFalse(fixture.controller.canEnableSound)
    XCTAssertEqual(await fixture.service.authorizationRequests, 0)
}
```

- [ ] **Step 2: Modify `StatusMenu`**

Add `notificationSettings: NotificationSettingsController` to the view and render:

```swift
sectionLabel("Notifications")
Toggle("Notifications", isOn: Binding(
    get: { notificationSettings.isEnabled },
    set: { enabled in
        Task { try? await notificationSettings.setNotificationsEnabled(enabled) }
    }
))
.disabled(notificationSettings.isChanging)

Toggle("Sound", isOn: Binding(
    get: { notificationSettings.isSoundEnabled },
    set: { notificationSettings.setSoundEnabled($0) }
))
.disabled(!notificationSettings.canEnableSound)

if let help = notificationSettings.helpText {
    Text(help).foregroundStyle(.secondary)
}
if let error = notificationSettings.errorMessage {
    Text(error).foregroundStyle(.red)
}
```

Keep Terminal, Launch at Login, retry, and Quit behavior unchanged. Do not add per-session controls or a system-settings URL.

- [ ] **Step 3: Compose exactly one live notification stack**

In `HerdrMenubarApp.init`, create in this order:

```swift
let preferences = Preferences()
let notificationService = NativeNotificationService()
let attentionCoordinator = AttentionNotificationCoordinator(service: notificationService)
let notificationSettings = NotificationSettingsController(
    service: notificationService,
    preferences: preferences
)
```

Inject the same service and coordinator into `AgentStore`, store the controller in `@State`, pass it to `StatusMenu`, and set an app-delegate reference before starting synchronization.

Add `var notificationSettings: NotificationSettingsController?` to `HerdrAppDelegate`; call `Task { await notificationSettings?.refreshStatus() }` from `applicationDidBecomeActive`. In the menu-bar `.task`, assign the delegate reference and await one initial refresh before `store.start()`.

- [ ] **Step 4: Update integration constructors and run GREEN**

Every test `AgentStore` construction must inject a recording coordinator and notification service; no test may instantiate `UNUserNotificationCenter.current()`. Run `NotificationSettingsControllerTests`, `AgentStoreTests`, and `MultiSessionIntegrationTests`, then build Debug.

Expected: tests pass; Debug build succeeds; no notification permission prompt appears during tests.

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/Menu/StatusMenu.swift HerdrMenubar/App/HerdrMenubarApp.swift HerdrMenubarTests/NotificationSettingsControllerTests.swift HerdrMenubarTests/MultiSessionIntegrationTests.swift
git commit -m "feat: expose native notification settings"
```

---

### Task 7: Prove two-session delivery and click routing end to end

**Files:**
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Add a two-socket notification integration test**

Use the existing `FakeHerdrServer` and integration wait helpers. Start default and named servers with duplicate pane IDs in `working`, start the real `SessionSupervisor`, real `AgentStore`, real coordinator, and a recording notification service. Then:

```swift
await namedServer.pushAgentStatusEvent(paneID: "duplicate", status: .blocked)
await eventually { await notifications.deliveries.count == 1 }
XCTAssertEqual(await notifications.deliveries[0].event.target,
    NotificationSelectionTarget(sessionID: .named("work"), paneID: "duplicate"))
XCTAssertFalse(await notifications.deliveries[0].sound)

await defaultServer.pushAgentStatusEvent(paneID: "duplicate", status: .done)
await eventually { await notifications.deliveries.count == 2 }
XCTAssertEqual(await notifications.deliveries.map(\.event.target.sessionID), [
    .named("work"), .default
])

await notifications.send(NotificationSelectionTarget(
    sessionID: .named("work"), paneID: "duplicate"
))
await eventually { await namedServer.focusedPaneIDs == ["duplicate"] }
XCTAssertEqual(await defaultServer.focusedPaneIDs, [])
```

Also prove an unchanged reconnect inside the held ten-second grace emits no third notification, and a permanent removal followed by recreation establishes a silent first baseline.

- [ ] **Step 2: Record RED, then make only test-fixture changes needed for GREEN**

Run only the new integration test before adding any missing fixture endpoints or recorders.

Expected RED: a missing fake recording/response seam or an unmet delivery/focus assertion. Add the smallest protocol-aware fixture changes, then rerun five consecutive times.

Expected GREEN: all five runs pass, with no `/tmp/hm-*` sockets or directories left behind.

- [ ] **Step 3: Update README**

Document:

- Notifications are opt-in from the menu and permission is requested in context.
- First snapshots and existing attention are silent.
- Every new blocked/done status transition creates one pane-specific notification.
- Sound is independently opt-in and defaults off.
- Clicking focuses the exact session/pane and existing WezTerm tab.
- Notification labels are visible to macOS and subject to the user's preview settings.
- Notification preferences are local app intent; macOS System Settings can still block alerts or sound.

Do not claim outage notifications, summaries, schedules, per-session preferences, custom actions, or new-tab creation.

- [ ] **Step 4: Run full automated validation**

Run:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
plutil -lint HerdrMenubar.xcodeproj/project.pbxproj HerdrMenubar/Info.plist HerdrMenubar/HerdrMenubar.entitlements
git diff --check
```

Expected: full suite, Release build, Analyze, plist checks, and diff check pass. Search all new logging for `.public` dynamic session names, pane IDs, labels, payload data, or errors; expected result is none.

- [ ] **Step 5: Install and manually smoke-test the signed app**

Run `./scripts/install.sh`. Verify the installed bundle identity/signature and launch it. With two real Herdr sessions:

1. Confirm Notifications and Sound initially display off.
2. Turn Notifications on and approve the contextual macOS prompt.
3. Confirm already blocked/done panes do not notify.
4. Trigger a new blocked transition and a later done transition; confirm distinct silent notifications.
5. Turn Sound on and confirm the next transition uses the standard system sound.
6. Click each session's notification and confirm the exact existing WezTerm tab and Herdr pane activates.
7. Keep the status menu open during another transition and confirm no banner or sound appears while the entry remains available in Notification Center.
8. Disable notification permission in System Settings, reactivate the app, and confirm inline help updates without disrupting the menu badge.
9. Quit normally and confirm no child process, temporary socket, or test artifact remains.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubarTests/MultiSessionIntegrationTests.swift README.md
git commit -m "test: verify native notifications end to end"
```

---

## Final self-review checklist

- [ ] Every design-spec goal and non-goal maps to a task above.
- [ ] Initial session baselines, later new panes, `blocked ↔ done`, duplicate snapshots, disabled periods, grace reconnect, removal, and reset have explicit tests.
- [ ] One live service instance owns authorization, delivery, foreground policy, and response buffering.
- [ ] Notification clicks and menu clicks share exact latest-wins selection ownership.
- [ ] Store stop/restart owns and awaits both event consumers and clears pending response state.
- [ ] No production default injects a live notification center into tests.
- [ ] No dynamic session, pane, label, payload, or error value is publicly logged.
- [ ] No summary, outage, schedule, custom action, per-session setting, or new-tab behavior entered scope.
