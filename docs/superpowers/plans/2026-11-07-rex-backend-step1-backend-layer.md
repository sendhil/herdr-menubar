# Rex Backend — Step 1: Backend Layer (Herdr Only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `AgentBackend` layer below `AgentStore`, make the existing Herdr supervisor the only backend (`HerdrBackend`), and re-key the store, notification coordinator, notification payload, shortcuts and menu on backend-neutral types, with **no user-visible change**.

**Architecture:** New shared value types and the `AgentBackend` protocol live in `Status/AgentBackend.swift`. `HerdrBackend` (`@MainActor`) wraps `SessionSupervising`, owns Herdr row/attention construction (moved from `AgentMenuItem`), Ghostty/terminal activation and Ghostty `forget`. `AgentStore` consumes `[any AgentBackend]`, keys sessions by `AgentSessionKey`, and runs the five-step selection flow. The coordinator keys history by `(AgentTarget, recordID)` storing `(state, epoch)`. `SelectionTarget` replaces `NotificationSelectionTarget` everywhere; notifications are written as payload v2 and v1/v2 both decode.

**Tech Stack:** Swift 6.0, AppKit, SwiftUI (icon view only), Observation, UserNotifications, XCTest, Xcode 26, macOS 26.0 deployment target, KeyboardShortcuts 3.0.1 (unchanged).

**Spec:** `docs/superpowers/specs/2026-11-07-rex-backend-design.md`, revision 5. This plan implements rollout step 1 only; steps 2 and 3 are outlined at the end.

## Global Constraints

- Step 1 produces **no user-visible change**: "Herdr-only installs see no change until rollout step 3". Every existing menu string, symbol, ordering, badge count, notification title/body, tooltip and accessibility string stays byte-identical for Herdr.
- Preserve the macOS 26.0 deployment target, `SWIFT_VERSION = 6.0`, and the KeyboardShortcuts 3.0.1 pin. Add no dependencies.
- `enum BackendKind: String, Codable, Sendable, CaseIterable { case herdr, rex }` — "declaration order = sort order".
- `AgentSessionKey.rawID` "encodes `.default` as `"default"` and `.named(n)` as `"named:" + n`".
- `SelectionTarget`: "Equality and hashing use `target` only; the display name is a message hint, refreshed from the store's current descriptor when one exists."
- Herdr records "always have `recordID ""` and `epoch 0`, and Herdr sends only attention states."
- Coordinator: "Each reconcile replaces the session's history with exactly the given records"; "A delivery candidate is a record whose `(state, epoch)` differs from history, including absent → present"; "Delivery condition: `notificationsEnabled && notifyStates(backend).contains(state)`. Unchecked states still update history."
- Preferences (exact keys/defaults): `notifyStates.herdr` absent means `["blocked","done"]`; `notifyStates.rex` absent means `["blocked","error"]`; `enabledBackends` absent means `["herdr"]` until step 3; `enabledBackends` is written by `defaults write` only. No UI for `enabledBackends` (non-goal).
- Payload "Version 2 keys: `version`, `backend`, `session_display_name`, `pane_id`, plus for Herdr the existing `session_kind`/`session_name`, and for Rex `rex_session_id`." "`isSupportedPayloadVersion` accepts 1 and 2."
- Titles: "**Agent blocked**, **Agent failed** (new), **Agent finished**." Herdr body unchanged: `<visible label> — <session>`.
- New status symbol for `error`: SF Symbol `xmark.octagon` (unreachable for Herdr in step 1).
- Strings take a `wording` input (`.herdr` or `.agents`); `.agents` only when Rex is active, so step 1 always renders `.herdr`.
- `HerdrBackend` is `@MainActor`; `kind` and `compareSessions` are `nonisolated`.
- Selection steps 0–5 exactly as the spec's "AgentStore changes → Selection", preserving `testSupersededSuccessfulSelectionCannotActivateAndStillRefreshes`.
- All tests stay hermetic: no live Herdr sockets, Ghostty Apple Events, TCC prompts or `rex` processes.
- Do not rename the app; do not touch `HerdrWidgets`, `WidgetShared`, `.worktrees/` or `integrations/`.
- New source files must be registered in `HerdrMenubar.xcodeproj/project.pbxproj` by hand (the project does not use synchronized folders). New object IDs use the unused prefix `BB0000000000000000000…`.

**Test commands used throughout** (run from `/Users/sendhil/src/herdr-menubar`):

```bash
# One test class
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/<ClassName>

# Full hermetic suite
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
```

A compile failure in any test file fails every `-only-testing` run; "FAIL" in a red step below means `** TEST FAILED **` (usually a compile error naming the missing symbol), "PASS" means `** TEST SUCCEEDED **`.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `HerdrMenubar/Status/AgentBackend.swift` | Create | `BackendKind`, `AgentSessionKey` (+ Herdr bridge), `AgentSessionDescriptor`, `AgentTarget`, `SelectionTarget`, `AttentionState`, `RowState`, `SeenToken`, `AgentRow` (+ ordering), `AttentionRecord`, `BackendSnapshot`, `BackendEvent`, `FocusError`, `AgentBackend` protocol. |
| `HerdrMenubar/Herdr/HerdrBackend.swift` | Create | `@MainActor` `AgentBackend` over `SessionSupervising`: event mapping, Herdr rows/attention (moved from `AgentMenuItem`), focus wording, Ghostty/terminal activation, Ghostty `forget`, session comparator, disabled → `.backendHidden`. |
| `HerdrMenubar/Status/AgentStore.swift` | Rewrite (Task 7), edit (Tasks 5, 6, 8) | Backend-neutral store keyed by `AgentSessionKey`; sections from `RowState`; selection steps 0–5; pending target; backend events; connection aggregation; wording. `AgentMenuItem`, `AgentMenuItemID`, `AgentSelectionTarget` are deleted. |
| `HerdrMenubar/Notifications/NotificationModels.swift` | Modify | Drop `NotificationSelectionTarget`; `AttentionNotificationEvent` on `SelectionTarget`/`AttentionState`; policy `notifyStates`; coordinator protocol on descriptors/records. |
| `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift` | Rewrite (Task 6) | `(AgentTarget, recordID)` → `(state, epoch)` history, per-backend state filter, delivery in given order. |
| `HerdrMenubar/Notifications/LatestNotificationTargetStore.swift` | Modify | `SelectionTarget`. |
| `HerdrMenubar/Notifications/NativeNotificationService.swift` | Modify | Payload v2 encode, v1+v2 decode, `Agent failed` title, broker on `SelectionTarget`. |
| `HerdrMenubar/Shortcuts/GlobalShortcutController.swift` | Modify | `SelectionTarget`. |
| `HerdrMenubar/App/ApplicationRuntime.swift` | Modify | `SelectionTarget`; `live()` builds `HerdrBackend` and `AgentStore(backends:…)`. |
| `HerdrMenubar/Menu/StatusMenuPresentation.swift` | Modify | `.agent`/`.select` on `SelectionTarget`; rows from `AgentRow`; `RowState` symbols; wording. |
| `HerdrMenubar/Menu/MenuBarIcon.swift` | Modify | `AgentWording`; `wording` input on presentation and accessibility value. |
| `HerdrMenubar/Menu/StatusItemController.swift` | Modify | Native renderer reads label/tooltip/symbol description from `presentation.wording`. |
| `HerdrMenubar/System/Preferences.swift` | Modify | `enabledBackends`, `notifyStates`, keys and defaults. |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Modify | Register the new files. |
| `HerdrMenubarTests/AgentBackendTypesTests.swift` | Create | Shared-type behaviour. |
| `HerdrMenubarTests/HerdrBackendTests.swift` | Create | `HerdrBackend` in isolation (including the five label tests moved from `AgentStoreTests`). |
| `HerdrMenubarTests/BackendTestSupport.swift` | Create | Test-only shims that keep the existing Herdr suites readable: `AgentSessionKey.default/.named`, `SelectionTarget.sessionID/.paneID`, `AgentRow.paneID`, pane-list `reconcile`, Herdr-only `AgentStore` convenience init, `select(_ row:)`. |
| `HerdrMenubarTests/AgentStoreBackendTests.swift` | Create | Store behaviour against a fake non-Herdr backend: selection steps, seen tokens, backend events, aggregation, wording. |
| Existing tests | Modify | Type migration (mostly mechanical `perl` rewrites listed per task). |

---

### Task 1: Shared backend types and the `AgentBackend` protocol

**Files:**
- Create: `HerdrMenubar/Status/AgentBackend.swift`
- Create: `HerdrMenubarTests/AgentBackendTypesTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SessionID`, `SessionDescriptor` (`HerdrMenubar/Herdr/SessionDiscovery.swift`).
- Produces (exact):
  - `enum BackendKind: String, Codable, Sendable, CaseIterable { case herdr, rex }` with `var displayName: String` (`"Herdr"`, `"Rex"`), `var sortIndex: Int`, `var defaultNotifyStates: Set<AttentionState>`.
  - `struct AgentSessionKey: Hashable, Sendable { let backend: BackendKind; let rawID: String }`, `init(herdr: SessionID)`, `var herdrSessionID: SessionID?`.
  - `struct AgentSessionDescriptor: Identifiable, Equatable, Sendable { let key; let displayName; var id: AgentSessionKey }`, `init(herdr: SessionDescriptor)`.
  - `struct AgentTarget: Hashable, Sendable { let session: AgentSessionKey; let paneID: String }`.
  - `struct SelectionTarget: Hashable, Sendable { let target: AgentTarget; let sessionDisplayName: String }` (equality/hash on `target`), `static func herdr(_ sessionID: SessionID, paneID: String) -> SelectionTarget`.
  - `enum AttentionState: String, Sendable { case blocked, error, done }`.
  - `enum RowState: Equatable, Sendable { case attention(AttentionState), finished, working }`.
  - `struct SeenToken: Hashable, Sendable { let marks: Set<String> }`.
  - `struct AgentRow: Identifiable, Equatable, Sendable { target, displayLabel, agentLabel: String?, state: RowState, subtitle, seenToken: SeenToken? }`, `var id: AgentTarget`, `var visibleLabel: String`, `static func attentionOrder(_:_:) -> Bool`, `static func labelOrder(_:_:) -> Bool`.
  - `struct AttentionRecord: Equatable, Sendable { target, recordID, epoch: Int, state: AttentionState, visibleLabel, message: String? }`.
  - `struct BackendSnapshot: Equatable, Sendable { rows: [AgentRow]; attention: [AttentionRecord]; static let empty }`.
  - `enum BackendEvent: Equatable, Sendable` with the eight spec cases.
  - `enum FocusError: LocalizedError, Equatable { case unavailable(String), failed(String) }`.
  - `protocol AgentBackend: Sendable` with the eleven spec requirements.

- [ ] **Step 1: Write the failing test**

Create `HerdrMenubarTests/AgentBackendTypesTests.swift`:

```swift
import Foundation
import XCTest
@testable import HerdrMenubar

final class AgentBackendTypesTests: XCTestCase {
    func testHerdrSessionKeysEncodeDefaultAndNamedDefaultDistinctly() {
        let defaultKey = AgentSessionKey(herdr: .default)
        let namedDefaultKey = AgentSessionKey(herdr: .named("default"))

        XCTAssertEqual(defaultKey, AgentSessionKey(backend: .herdr, rawID: "default"))
        XCTAssertEqual(namedDefaultKey, AgentSessionKey(backend: .herdr, rawID: "named:default"))
        XCTAssertNotEqual(defaultKey, namedDefaultKey)
        XCTAssertEqual(defaultKey.herdrSessionID, .default)
        XCTAssertEqual(namedDefaultKey.herdrSessionID, .named("default"))
        XCTAssertEqual(AgentSessionKey(herdr: .named("a:b")).rawID, "named:a:b")
        XCTAssertEqual(AgentSessionKey(herdr: .named("a:b")).herdrSessionID, .named("a:b"))
    }

    func testOnlyWellFormedHerdrKeysBridgeBackToSessionID() {
        XCTAssertNil(AgentSessionKey(backend: .rex, rawID: "default").herdrSessionID)
        XCTAssertNil(AgentSessionKey(backend: .herdr, rawID: "work").herdrSessionID)
        XCTAssertNil(AgentSessionKey(backend: .herdr, rawID: "named:").herdrSessionID)
    }

    func testBackendKindOrderNamesAndDefaultNotifyStates() {
        XCTAssertEqual(BackendKind.allCases, [.herdr, .rex])
        XCTAssertLessThan(BackendKind.herdr.sortIndex, BackendKind.rex.sortIndex)
        XCTAssertEqual(BackendKind.herdr.displayName, "Herdr")
        XCTAssertEqual(BackendKind.rex.displayName, "Rex")
        XCTAssertEqual(BackendKind.herdr.defaultNotifyStates, [.blocked, .done])
        XCTAssertEqual(BackendKind.rex.defaultNotifyStates, [.blocked, .error])
    }

    func testHerdrDescriptorBridgeKeepsDisplayName() {
        let descriptor = SessionDescriptor(id: .named("work"), socketURL: URL(fileURLWithPath: "/tmp/work.sock"))
        XCTAssertEqual(
            AgentSessionDescriptor(herdr: descriptor),
            AgentSessionDescriptor(key: AgentSessionKey(backend: .herdr, rawID: "named:work"), displayName: "work")
        )
        XCTAssertEqual(
            AgentSessionDescriptor(
                herdr: SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/default.sock"))
            ).displayName,
            "Default"
        )
    }

    func testSelectionTargetEqualityAndHashIgnoreDisplayName() {
        let target = AgentTarget(session: AgentSessionKey(herdr: .named("work")), paneID: "p1")
        let first = SelectionTarget(target: target, sessionDisplayName: "work")
        let renamed = SelectionTarget(target: target, sessionDisplayName: "Renamed")
        let otherPane = SelectionTarget(
            target: AgentTarget(session: target.session, paneID: "p2"),
            sessionDisplayName: "work"
        )

        XCTAssertEqual(first, renamed)
        XCTAssertEqual(Set([first, renamed]).count, 1)
        XCTAssertNotEqual(first, otherPane)
    }

    func testHerdrSelectionTargetUsesSessionIDDisplayName() {
        let target = SelectionTarget.herdr(.default, paneID: "p")
        XCTAssertEqual(target.target, AgentTarget(session: AgentSessionKey(herdr: .default), paneID: "p"))
        XCTAssertEqual(target.sessionDisplayName, "Default")
        XCTAssertEqual(SelectionTarget.herdr(.named("work"), paneID: "p").sessionDisplayName, "work")
    }

    func testVisibleLabelOmitsMissingOrDuplicateAgentLabel() {
        XCTAssertEqual(row("p", label: "api", agent: "claude", state: .working).visibleLabel, "api · claude")
        XCTAssertEqual(row("p", label: "claude", agent: "claude", state: .working).visibleLabel, "claude")
        XCTAssertEqual(row("p", label: "Review", agent: nil, state: .finished).visibleLabel, "Review")
    }

    func testAttentionOrderRanksBlockedErrorDoneThenFoldedLabelThenPaneID() {
        let rows = [
            row("d", label: "a", agent: nil, state: .attention(.done)),
            row("e", label: "z", agent: nil, state: .attention(.error)),
            row("b2", label: "Beta", agent: nil, state: .attention(.blocked)),
            row("b1", label: "beta", agent: nil, state: .attention(.blocked)),
            row("b0", label: "alpha", agent: nil, state: .attention(.blocked))
        ]
        XCTAssertEqual(rows.sorted(by: AgentRow.attentionOrder).map(\.target.paneID), ["b0", "b1", "b2", "e", "d"])
        XCTAssertEqual(rows.sorted(by: AgentRow.labelOrder).map(\.target.paneID), ["d", "b0", "b1", "b2", "e"])
    }

    func testFocusErrorDescriptionIsTheFinalMessage() {
        XCTAssertEqual(FocusError.failed("Could not focus pane in work: gone").localizedDescription,
                       "Could not focus pane in work: gone")
        XCTAssertEqual(FocusError.unavailable("Rex is not running").localizedDescription, "Rex is not running")
    }

    private func row(_ paneID: String, label: String, agent: String?, state: RowState) -> AgentRow {
        AgentRow(
            target: AgentTarget(session: AgentSessionKey(herdr: .default), paneID: paneID),
            displayLabel: label,
            agentLabel: agent,
            state: state,
            subtitle: "",
            seenToken: nil
        )
    }
}
```

- [ ] **Step 2: Register the new files in the Xcode project**

Edit `HerdrMenubar.xcodeproj/project.pbxproj` (four insertions per file; each anchor line is unique):

1. After the line
   `		12A00000000000000000000A /* AgentStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = 12A000000000000000000020 /* AgentStore.swift */; };`
   insert
   ```
   		BB0000000000000000000001 /* AgentBackend.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000011 /* AgentBackend.swift */; };
   		BB0000000000000000000002 /* AgentBackendTypesTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000012 /* AgentBackendTypesTests.swift */; };
   ```
2. After the line
   `		12A000000000000000000020 /* AgentStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentStore.swift; sourceTree = "<group>"; };`
   insert
   ```
   		BB0000000000000000000011 /* AgentBackend.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentBackend.swift; sourceTree = "<group>"; };
   		BB0000000000000000000012 /* AgentBackendTypesTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentBackendTypesTests.swift; sourceTree = "<group>"; };
   ```
3. In the `Status` group, after `				12A000000000000000000020 /* AgentStore.swift */,` insert `				BB0000000000000000000011 /* AgentBackend.swift */,`
   In the `HerdrMenubarTests` group, after `				12A000000000000000000019 /* AgentStoreTests.swift */,` insert `				BB0000000000000000000012 /* AgentBackendTypesTests.swift */,`
4. In the app Sources phase, after `				12A00000000000000000000A /* AgentStore.swift in Sources */,` insert `				BB0000000000000000000001 /* AgentBackend.swift in Sources */,`
   In the test Sources phase, after `				12A000000000000000000009 /* AgentStoreTests.swift in Sources */,` insert `				BB0000000000000000000002 /* AgentBackendTypesTests.swift in Sources */,`

Create an empty placeholder so the reference resolves: `touch HerdrMenubar/Status/AgentBackend.swift`.

Run: `xcodebuild -list -project HerdrMenubar.xcodeproj`
Expected: lists targets `HerdrMenubar`, `HerdrMenubarTests`, `HerdrMenubarUITests` (project still parses).

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/AgentBackendTypesTests`
Expected: FAIL — `cannot find 'AgentSessionKey' in scope`.

- [ ] **Step 4: Write the implementation**

Write `HerdrMenubar/Status/AgentBackend.swift`:

```swift
import Foundation

/// Declaration order is the menu's session sort order.
enum BackendKind: String, Codable, Sendable, CaseIterable {
    case herdr
    case rex

    var displayName: String {
        switch self {
        case .herdr: "Herdr"
        case .rex: "Rex"
        }
    }

    var sortIndex: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }

    /// States that notify when `notifyStates.<backend>` is absent.
    var defaultNotifyStates: Set<AttentionState> {
        switch self {
        case .herdr: [.blocked, .done]
        case .rex: [.blocked, .error]
        }
    }
}

struct AgentSessionKey: Hashable, Sendable {
    let backend: BackendKind
    /// Herdr: "default" or "named:<name>"; Rex: session_id.
    let rawID: String
}

extension AgentSessionKey {
    private static let herdrDefaultRawID = "default"
    private static let herdrNamedPrefix = "named:"

    init(herdr sessionID: SessionID) {
        switch sessionID {
        case .default:
            self.init(backend: .herdr, rawID: Self.herdrDefaultRawID)
        case .named(let name):
            self.init(backend: .herdr, rawID: Self.herdrNamedPrefix + name)
        }
    }

    /// The Herdr session this key names; nil for other backends and malformed raw IDs.
    var herdrSessionID: SessionID? {
        guard backend == .herdr else { return nil }
        if rawID == Self.herdrDefaultRawID { return .default }
        guard rawID.hasPrefix(Self.herdrNamedPrefix) else { return nil }
        let name = String(rawID.dropFirst(Self.herdrNamedPrefix.count))
        return name.isEmpty ? nil : .named(name)
    }
}

struct AgentSessionDescriptor: Identifiable, Equatable, Sendable {
    let key: AgentSessionKey
    let displayName: String
    var id: AgentSessionKey { key }
}

extension AgentSessionDescriptor {
    init(herdr descriptor: SessionDescriptor) {
        self.init(key: AgentSessionKey(herdr: descriptor.id), displayName: descriptor.displayName)
    }
}

struct AgentTarget: Hashable, Sendable {
    let session: AgentSessionKey
    /// Herdr: pane_id; Rex: block_id.
    let paneID: String
}

/// Replaces NotificationSelectionTarget everywhere.
/// Equality and hashing use `target` only; the display name is a message hint, refreshed from
/// the store's current descriptor when one exists.
struct SelectionTarget: Hashable, Sendable {
    let target: AgentTarget
    let sessionDisplayName: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(target)
    }

    static func herdr(_ sessionID: SessionID, paneID: String) -> SelectionTarget {
        SelectionTarget(
            target: AgentTarget(session: AgentSessionKey(herdr: sessionID), paneID: paneID),
            sessionDisplayName: sessionID.displayName
        )
    }
}

enum AttentionState: String, Sendable {
    case blocked
    case error
    case done
}

enum RowState: Equatable, Sendable {
    /// NEEDS ATTENTION; counted in the badge.
    case attention(AttentionState)
    /// FINISHED; not counted (Rex done).
    case finished
    /// WORKING.
    case working
}

/// Opaque to the store.
struct SeenToken: Hashable, Sendable {
    let marks: Set<String>
}

/// A final row: already seen-filtered and ranked by its backend.
struct AgentRow: Identifiable, Equatable, Sendable {
    let target: AgentTarget
    /// Primary label (Herdr: workspace/tab/pane label).
    let displayLabel: String
    let agentLabel: String?
    let state: RowState
    /// Full secondary line built by the backend (Herdr: "status · agentLabel").
    let subtitle: String
    let seenToken: SeenToken?

    var id: AgentTarget { target }

    var visibleLabel: String {
        guard let agentLabel, agentLabel != displayLabel else { return displayLabel }
        return "\(displayLabel) · \(agentLabel)"
    }

    /// blocked, error, done, then label.
    static func attentionOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsRank = lhs.attentionRank
        let rhsRank = rhs.attentionRank
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return labelOrder(lhs, rhs)
    }

    static func labelOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let lhsLabel = lhs.displayLabel.folding(options: [.caseInsensitive], locale: locale)
        let rhsLabel = rhs.displayLabel.folding(options: [.caseInsensitive], locale: locale)
        if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
        return lhs.target.paneID < rhs.target.paneID
    }

    private var attentionRank: Int {
        switch state {
        case .attention(.blocked): 0
        case .attention(.error): 1
        case .attention(.done): 2
        case .finished, .working: 3
        }
    }
}

/// Coordinator input; never seen-filtered.
struct AttentionRecord: Equatable, Sendable {
    let target: AgentTarget
    /// Herdr: ""; Rex: record id.
    let recordID: String
    /// Herdr: 0; Rex: record epoch.
    let epoch: Int
    let state: AttentionState
    let visibleLabel: String
    /// Sanitized; Rex only.
    let message: String?
}

struct BackendSnapshot: Equatable, Sendable {
    let rows: [AgentRow]
    /// In delivery order (Herdr: label order).
    let attention: [AttentionRecord]

    static let empty = BackendSnapshot(rows: [], attention: [])
}

enum BackendEvent: Equatable, Sendable {
    /// Complete session set.
    case discovery([AgentSessionDescriptor])
    case connected(AgentSessionDescriptor, BackendSnapshot)
    case snapshot(AgentSessionKey, BackendSnapshot)
    case descriptorChanged(AgentSessionDescriptor)
    case sessionUnavailable(AgentSessionKey, String)
    case removed(AgentSessionKey)
    /// Whole backend down; history kept.
    case backendUnavailable(String)
    /// Not installed or disabled.
    case backendHidden
}

/// The message is final, user-facing text.
enum FocusError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        }
    }
}

protocol AgentBackend: Sendable {
    var kind: BackendKind { get }
    func events() async -> AsyncStream<BackendEvent>
    /// Returns promptly; work happens in tasks.
    func start() async
    func stop() async
    func retryUnavailable() async
    /// Cancellable.
    func focusServer(_ target: AgentTarget) async throws
    /// nil = success, else a partial-focus message.
    func activate(_ target: AgentTarget) async -> String?
    /// Called after a completed `focusServer`.
    func refreshAfterSelection(_ target: AgentTarget) async
    func markSeen(_ token: SeenToken) async
    func clearFinished() async
    func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/AgentBackendTypesTests`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Status/AgentBackend.swift HerdrMenubarTests/AgentBackendTypesTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: add agent backend types and protocol"
```

---

### Task 2: Backend preference keys (`enabledBackends`, `notifyStates.*`)

**Files:**
- Modify: `HerdrMenubar/System/Preferences.swift`
- Test: `HerdrMenubarTests/PreferencesTests.swift`

**Interfaces:**
- Consumes: `BackendKind`, `AttentionState`, `BackendKind.defaultNotifyStates` (Task 1).
- Produces:
  - `static let enabledBackendsKey = "enabledBackends"`
  - `static let defaultEnabledBackends: Set<BackendKind> = [.herdr]`
  - `static func notifyStatesKey(for kind: BackendKind) -> String` → `"notifyStates.herdr"` / `"notifyStates.rex"`
  - `let enabledBackends: Set<BackendKind>` (read once at init)
  - `private(set) var notifyStates: [BackendKind: Set<AttentionState>]` (always has an entry per `BackendKind`)
  - `func setNotifyStates(_ states: Set<AttentionState>, for kind: BackendKind)` (writes sorted raw values)

- [ ] **Step 1: Write the failing tests**

Append inside `PreferencesTests` (before the `private func withDefaults`):

```swift
    func testBackendPreferencesDefaultToSpecValuesWithoutWriting() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)

            XCTAssertEqual(preferences.enabledBackends, [.herdr])
            XCTAssertEqual(preferences.notifyStates, [.herdr: [.blocked, .done], .rex: [.blocked, .error]])
            XCTAssertNil(defaults.object(forKey: "enabledBackends"))
            XCTAssertNil(defaults.object(forKey: "notifyStates.herdr"))
            XCTAssertNil(defaults.object(forKey: "notifyStates.rex"))
        }
    }

    func testEnabledBackendsReadsDefaultsWriteValueAndIgnoresUnknownNames() {
        withDefaults { defaults in
            defaults.set(["rex", "wezterm", "herdr"], forKey: "enabledBackends")
            XCTAssertEqual(Preferences(defaults: defaults).enabledBackends, [.herdr, .rex])

            defaults.set([String](), forKey: "enabledBackends")
            XCTAssertEqual(Preferences(defaults: defaults).enabledBackends, [])
        }
    }

    func testNotifyStatesPersistPerBackendOnlyWhenChanged() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)

            preferences.setNotifyStates([.blocked], for: .herdr)
            XCTAssertEqual(preferences.notifyStates[.herdr], [.blocked])
            XCTAssertEqual(defaults.stringArray(forKey: "notifyStates.herdr"), ["blocked"])
            XCTAssertNil(defaults.object(forKey: "notifyStates.rex"))

            preferences.setNotifyStates([.error, .done, .blocked], for: .rex)
            XCTAssertEqual(defaults.stringArray(forKey: "notifyStates.rex"), ["blocked", "done", "error"])

            let reloaded = Preferences(defaults: defaults)
            XCTAssertEqual(reloaded.notifyStates[.herdr], [.blocked])
            XCTAssertEqual(reloaded.notifyStates[.rex], [.blocked, .done, .error])
        }
    }

    func testStoredNotifyStatesIgnoreUnknownValuesAndMayBeEmpty() {
        withDefaults { defaults in
            defaults.set(["blocked", "exploded"], forKey: "notifyStates.rex")
            defaults.set([String](), forKey: "notifyStates.herdr")
            let preferences = Preferences(defaults: defaults)

            XCTAssertEqual(preferences.notifyStates[.rex], [.blocked])
            XCTAssertEqual(preferences.notifyStates[.herdr], [])
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/PreferencesTests`
Expected: FAIL — `value of type 'Preferences' has no member 'enabledBackends'`.

- [ ] **Step 3: Implement**

In `HerdrMenubar/System/Preferences.swift`, add after `static let notificationSoundEnabledKey = "notificationSoundEnabled"`:

```swift
    static let enabledBackendsKey = "enabledBackends"
    static let defaultEnabledBackends: Set<BackendKind> = [.herdr]

    static func notifyStatesKey(for kind: BackendKind) -> String {
        "notifyStates.\(kind.rawValue)"
    }
```

Add after the `notificationSoundEnabled` property:

```swift
    /// Read once at launch. Changed only with `defaults write`; there is no UI.
    let enabledBackends: Set<BackendKind>

    /// One entry per backend. Absent keys use `BackendKind.defaultNotifyStates` and are not written.
    private(set) var notifyStates: [BackendKind: Set<AttentionState>]

    func setNotifyStates(_ states: Set<AttentionState>, for kind: BackendKind) {
        notifyStates[kind] = states
        defaults.set(states.map(\.rawValue).sorted(), forKey: Self.notifyStatesKey(for: kind))
    }
```

At the end of `init(defaults:)`, after `notificationSoundEnabled = …`:

```swift
        enabledBackends = defaults.stringArray(forKey: Self.enabledBackendsKey)
            .map { Set($0.compactMap(BackendKind.init(rawValue:))) }
            ?? Self.defaultEnabledBackends
        notifyStates = Dictionary(uniqueKeysWithValues: BackendKind.allCases.map { kind in
            let stored = defaults.stringArray(forKey: Self.notifyStatesKey(for: kind))
                .map { Set($0.compactMap(AttentionState.init(rawValue:))) }
            return (kind, stored ?? kind.defaultNotifyStates)
        })
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/PreferencesTests`
Expected: PASS (existing tests plus 4 new).

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/System/Preferences.swift HerdrMenubarTests/PreferencesTests.swift
git commit -m "feat: add enabledBackends and per-backend notifyStates preferences"
```

---

### Task 3: `AgentWording` input for user-visible "Herdr" strings (defaults to `.herdr`)

**Files:**
- Modify: `HerdrMenubar/Menu/MenuBarIcon.swift`
- Modify: `HerdrMenubar/Menu/StatusItemController.swift:332-367` (`NativeStatusItemIconRenderer.apply`, `makeImage`)
- Modify: `HerdrMenubar/Menu/StatusMenuPresentation.swift` (`make`, `makeMenu`, `connectionNode`)
- Test: `HerdrMenubarTests/MenuBarIconTests.swift`, `HerdrMenubarTests/StatusItemControllerTests.swift`

**Interfaces:**
- Produces:
  - `enum AgentWording: Equatable, Sendable { case herdr, agents }` with `accessibilityLabel`, `tooltipPrefix`, `symbolDescription`, `sessionsNoun`.
  - `MenuBarIconPresentation.init(connectionState:attentionCount:wording: AgentWording = .herdr)` and stored `let wording: AgentWording`.
  - `MenuBarIcon.accessibilityValue(connectionState:attentionCount:wording: AgentWording = .herdr) -> String`.
  - `StatusMenuPresentationBuilder` threads a `wording` value (constant `.herdr` until Task 8 swaps in `store.wording`).
- The SketchyBar summary is `accessibilityValue`, so it follows automatically.

- [ ] **Step 1: Write the failing tests**

Append to `MenuBarIconTests` (inside the class, before `assertDisconnected`):

```swift
    func testPresentationDefaultsToHerdrWording() {
        XCTAssertEqual(MenuBarIconPresentation(connectionState: .searching, attentionCount: 0).wording, .herdr)
    }

    func testAgentsWordingSubstitutesSessionNounOnly() {
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .searching, attentionCount: 0, wording: .agents),
            "Searching for agent sessions"
        )
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .noSessions, attentionCount: 0, wording: .agents),
            "No agent sessions running"
        )
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connecting, attentionCount: 0, wording: .agents),
            "Connecting to agent sessions"
        )
        XCTAssertEqual(
            MenuBarIcon.accessibilityValue(connectionState: .connected, attentionCount: 2, wording: .agents),
            "Connected, 2 agents need attention"
        )
        XCTAssertEqual(AgentWording.agents.accessibilityLabel, "Agents")
        XCTAssertEqual(AgentWording.agents.tooltipPrefix, "Agents — ")
        XCTAssertEqual(AgentWording.agents.symbolDescription, "Agent status")
        XCTAssertEqual(AgentWording.herdr.accessibilityLabel, "Herdr")
        XCTAssertEqual(AgentWording.herdr.tooltipPrefix, "Herdr — ")
        XCTAssertEqual(AgentWording.herdr.symbolDescription, "Herdr terminal status")
    }
```

In `StatusItemControllerTests.testNativeIconApplicationPreservesExactAttentionCountAndAccessibility`, add after `XCTAssertEqual(button.accessibilityValue() as? String, "snapshot 12")`:

```swift
        XCTAssertEqual(button.toolTip, "Herdr — snapshot 12")
```

and add a new test in the same class:

```swift
    func testNativeIconUsesAgentsWordingForLabelAndTooltip() {
        let button = NSButton()
        NativeStatusItemIconRenderer.apply(
            MenuBarIconPresentation(connectionState: .connected, attentionCount: 1, wording: .agents),
            accessibilityValue: "Connected, 1 agent needs attention",
            to: button
        )

        XCTAssertEqual(button.accessibilityLabel(), "Agents")
        XCTAssertEqual(button.toolTip, "Agents — Connected, 1 agent needs attention")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/MenuBarIconTests -only-testing:HerdrMenubarTests/StatusItemControllerTests`
Expected: FAIL — `cannot find 'AgentWording' in scope` / `extra argument 'wording' in call`.

- [ ] **Step 3: Implement**

Replace `HerdrMenubar/Menu/MenuBarIcon.swift` with:

```swift
import SwiftUI

/// User-visible product wording. `.agents` is used only while Rex is active.
enum AgentWording: Equatable, Sendable {
    case herdr
    case agents

    var accessibilityLabel: String {
        switch self {
        case .herdr: "Herdr"
        case .agents: "Agents"
        }
    }

    var tooltipPrefix: String { "\(accessibilityLabel) — " }

    var symbolDescription: String {
        switch self {
        case .herdr: "Herdr terminal status"
        case .agents: "Agent status"
        }
    }

    var sessionsNoun: String {
        switch self {
        case .herdr: "Herdr sessions"
        case .agents: "agent sessions"
        }
    }
}

struct MenuBarIconPresentation: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case disconnected
        case clear
        case attention
    }

    let mode: Mode
    let opacity: Double
    let attentionCount: Int
    let showsAttentionCount: Bool
    let wording: AgentWording

    init(connectionState: ConnectionState, attentionCount: Int, wording: AgentWording = .herdr) {
        self.attentionCount = attentionCount
        self.wording = wording
        switch connectionState {
        case .searching, .noSessions, .connecting:
            mode = .disconnected
            opacity = 0.55
            showsAttentionCount = false
        case .connected where attentionCount > 0:
            mode = .attention
            opacity = 1
            showsAttentionCount = true
        case .connected:
            mode = .clear
            opacity = 1
            showsAttentionCount = false
        }
    }
}

struct MenuBarIcon: View {
    let connectionState: ConnectionState
    let attentionCount: Int
    var wording: AgentWording = .herdr

    static func accessibilityValue(
        connectionState: ConnectionState,
        attentionCount: Int,
        wording: AgentWording = .herdr
    ) -> String {
        switch connectionState {
        case .searching:
            return "Searching for \(wording.sessionsNoun)"
        case .noSessions:
            return "No \(wording.sessionsNoun) running"
        case .connecting:
            return "Connecting to \(wording.sessionsNoun)"
        case .connected where attentionCount == 0:
            return "Connected, no agents need attention"
        case .connected where attentionCount == 1:
            return "Connected, 1 agent needs attention"
        case .connected:
            return "Connected, \(attentionCount) agents need attention"
        }
    }

    var body: some View {
        let presentation = MenuBarIconPresentation(
            connectionState: connectionState,
            attentionCount: attentionCount,
            wording: wording
        )

        HStack(spacing: 2) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .regular))

            if presentation.showsAttentionCount {
                Text("\(attentionCount)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .opacity(presentation.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wording.accessibilityLabel)
        .accessibilityValue(Self.accessibilityValue(
            connectionState: connectionState,
            attentionCount: attentionCount,
            wording: wording
        ))
    }
}
```

In `HerdrMenubar/Menu/StatusItemController.swift`, in `NativeStatusItemIconRenderer.apply`, replace

```swift
        button.image = makeImage()
```
with
```swift
        button.image = makeImage(description: presentation.wording.symbolDescription)
```
and replace
```swift
        button.setAccessibilityLabel("Herdr")
        button.setAccessibilityValue(accessibilityValue)
        button.toolTip = "Herdr — \(accessibilityValue)"
```
with
```swift
        button.setAccessibilityLabel(presentation.wording.accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.toolTip = presentation.wording.tooltipPrefix + accessibilityValue
```
and change `makeImage`'s signature and symbol lookup:
```swift
    private static func makeImage(description: String) -> NSImage? {
        guard let terminal = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: description
        )?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) else {
```
(the rest of `makeImage` is unchanged).

In `HerdrMenubar/Menu/StatusMenuPresentation.swift`, replace the body of `make(…)` with:

```swift
        let wording = AgentWording.herdr
        return StatusItemPresentation(
            icon: MenuBarIconPresentation(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount,
                wording: wording
            ),
            accessibilityValue: MenuBarIcon.accessibilityValue(
                connectionState: store.connectionState,
                attentionCount: store.attentionCount,
                wording: wording
            ),
            menu: makeMenu(
                store: store,
                preferences: preferences,
                terminals: terminals,
                loginItem: loginItem,
                notifications: notifications,
                wording: wording
            )
        )
```

Add `wording: AgentWording` as the last parameter of `makeMenu(…)`, pass it to `connectionNode`:

```swift
        if let connectionNode = connectionNode(
            state: store.connectionState,
            hasPresentedAgents: !store.attentionSections.isEmpty || !store.workingSections.isEmpty,
            wording: wording
        ) {
```

and replace `connectionNode` with:

```swift
    func connectionNode(
        state: ConnectionState,
        hasPresentedAgents: Bool,
        wording: AgentWording
    ) -> StatusMenuNode? {
        switch state {
        case .searching:
            return .info("Searching for \(wording.sessionsNoun)…", tone: .secondary)
        case .noSessions:
            return .info("No \(wording.sessionsNoun) running", tone: .secondary)
        case .connecting:
            return .info("Connecting to \(wording.sessionsNoun)…", tone: .secondary)
        case .connected where !hasPresentedAgents:
            return .info("No active agents", tone: .secondary)
        case .connected:
            return nil
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass (and Herdr copy is unchanged)**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/MenuBarIconTests -only-testing:HerdrMenubarTests/StatusItemControllerTests -only-testing:HerdrMenubarTests/StatusMenuPresentationTests -only-testing:HerdrMenubarTests/SketchyBarIntegrationTests`
Expected: PASS. `StatusMenuPresentationTests.testSearchingSnapshotReproducesCompleteBaseMenu` and `testNoSessionsConnectingAndConnectedIdleUseExactConnectionCopy` prove the Herdr strings are byte-identical.

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/Menu/MenuBarIcon.swift HerdrMenubar/Menu/StatusItemController.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubarTests/MenuBarIconTests.swift HerdrMenubarTests/StatusItemControllerTests.swift
git commit -m "feat: thread agent wording through status strings"
```

---

### Task 4: `HerdrBackend`

**Files:**
- Create: `HerdrMenubar/Herdr/HerdrBackend.swift`
- Create: `HerdrMenubarTests/HerdrBackendTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SessionSupervising`, `SessionSupervisorEvent`, `PresentationSnapshot`, `PaneInfo`, `WorkspaceInfo`, `TabInfo`, `TerminalActivating`, `GhosttySessionFocusing`, `GhosttyFocusError`, `GhosttyControlConstants.bundleIdentifier`, `Preferences.enabledBackends`, `Preferences.selectedTerminalBundleIdentifier`, all Task 1 types.
- Produces:
  - `@MainActor final class HerdrBackend: AgentBackend`
  - `init(supervisor: any SessionSupervising, terminalActivator: any TerminalActivating, ghosttyFocuser: any GhosttySessionFocusing, preferences: Preferences)`
  - `nonisolated static func makeSnapshot(_ snapshot: PresentationSnapshot, sessionID: SessionID) -> BackendSnapshot` — rows in snapshot order (not deduplicated, as today's menu); attention deduplicated by pane ID (last occurrence wins, before status filtering, as today's coordinator), label-ordered, `recordID ""`, `epoch 0`.
  - `nonisolated static func row(for pane: PaneInfo, sessionID: SessionID, workspace: WorkspaceInfo? = nil, tab: TabInfo? = nil, workspaceIsMultiTab: Bool = false) -> AgentRow?` — nil for `idle`/`unknown`.
  - `nonisolated static func sessionOrder(_ lhs: SessionID, _ rhs: SessionID) -> Bool` — today's comparator verbatim.
  - `nonisolated static func ghosttyFocusMessage(_ error: any Error, sessionName: String) -> String` — today's wording verbatim.
  - Focus failure: `FocusError.failed("Could not focus pane in <SessionID.displayName>: <error.localizedDescription>")`.
- The store is not touched in this task; it keeps its own copy of the Ghostty wording until Task 7 deletes it.

- [ ] **Step 1: Write the failing tests**

Create `HerdrMenubarTests/HerdrBackendTests.swift`:

```swift
import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class HerdrBackendTests: XCTestCase {
    // MARK: Rows and attention records

    func testSnapshotBuildsRowsOnlyForAttentionAndWorkingPanesInSnapshotOrder() {
        let snapshot = herdrSnapshot([
            herdrPane("idle", .idle), herdrPane("blocked", .blocked), herdrPane("unknown", .unknown),
            herdrPane("working", .working), herdrPane("done", .done)
        ])

        let rows = HerdrBackend.makeSnapshot(snapshot, sessionID: .named("work")).rows

        XCTAssertEqual(rows.map(\.target.paneID), ["blocked", "working", "done"])
        XCTAssertEqual(rows.map(\.state), [.attention(.blocked), .working, .attention(.done)])
        XCTAssertEqual(rows.map(\.subtitle), ["blocked · Claude", "working · Claude", "done · Claude"])
        XCTAssertEqual(rows.map(\.agentLabel), ["Claude", "Claude", "Claude"])
        XCTAssertTrue(rows.allSatisfy { $0.seenToken == nil })
        XCTAssertTrue(rows.allSatisfy { $0.target.session == AgentSessionKey(herdr: .named("work")) })
    }

    func testAttentionRecordsAreLabelOrderedDeduplicatedLastWinsAndHerdrShaped() {
        let snapshot = herdrSnapshot([
            herdrPane("z", .blocked, title: "Zulu"),
            herdrPane("b", .done, title: "Alpha"),
            herdrPane("a", .blocked, title: "alpha"),
            herdrPane("dup", .blocked, title: "Dup"),
            herdrPane("dup", .working, title: "Dup"),
            herdrPane("w", .working, title: "Working")
        ])

        let attention = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).attention

        XCTAssertEqual(attention.map(\.target.paneID), ["a", "b", "z"])
        XCTAssertEqual(attention.map(\.state), [.blocked, .done, .blocked])
        XCTAssertEqual(attention.map(\.visibleLabel), ["alpha · Claude", "Alpha · Claude", "Zulu · Claude"])
        XCTAssertTrue(attention.allSatisfy { $0.recordID == "" && $0.epoch == 0 && $0.message == nil })
    }

    func testNamedDefaultAndDefaultProduceDistinctTargets() {
        let snapshot = herdrSnapshot([herdrPane("same", .done)])
        let defaultRow = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).rows[0]
        let namedRow = HerdrBackend.makeSnapshot(snapshot, sessionID: .named("default")).rows[0]
        XCTAssertNotEqual(defaultRow.target, namedRow.target)
    }

    func testJoinedLabelsMatchHerdrForSingleAndMultiTabWorkspaces() {
        let snapshot = PresentationSnapshot(
            panes: [
                herdrPane("single", .done, workspaceID: "dotfiles", tabID: "dotfiles:tab"),
                herdrPane("multi", .done, workspaceID: "menubar", tabID: "menubar:server")
            ],
            workspaces: [
                herdrWorkspace("dotfiles", label: "dotfiles-mac", tabCount: 1),
                herdrWorkspace("menubar", label: "Herdr Menubar", tabCount: 2)
            ],
            tabs: [
                herdrTab("dotfiles:tab", workspaceID: "dotfiles", label: "shell"),
                herdrTab("menubar:server", workspaceID: "menubar", label: "server")
            ]
        )

        let rows = HerdrBackend.makeSnapshot(snapshot, sessionID: .default).rows

        XCTAssertEqual(rows.map(\.displayLabel), ["dotfiles-mac", "Herdr Menubar · server"])
        XCTAssertEqual(rows.map(\.subtitle), ["done · Claude", "done · Claude"])
    }

    func testVisibleLabelsIncludeAgentContextWithoutDuplicateSuffixes() throws {
        let labeledAgentPane = PaneInfo(
            paneID: "bin:pane", terminalID: "terminal", workspaceID: "bin", tabID: "bin:tab",
            focused: false, label: "test-agent", agent: "pi", title: nil, displayAgent: nil,
            agentStatus: .blocked, revision: 1
        )
        let singleTab = try XCTUnwrap(HerdrBackend.row(
            for: labeledAgentPane, sessionID: .default,
            workspace: herdrWorkspace("bin", label: "bin", tabCount: 1),
            tab: herdrTab("bin:tab", workspaceID: "bin", label: "shell")
        ))
        let multiTab = try XCTUnwrap(HerdrBackend.row(
            for: labeledAgentPane, sessionID: .default,
            workspace: herdrWorkspace("workspace", label: "workspace", tabCount: 2),
            tab: herdrTab("workspace:test", workspaceID: "workspace", label: "tab"),
            workspaceIsMultiTab: true
        ))
        let duplicate = try XCTUnwrap(HerdrBackend.row(
            for: labeledAgentPane, sessionID: .default,
            workspace: herdrWorkspace("bin", label: "test-agent", tabCount: 1)
        ))
        let fallbackPane = PaneInfo(
            paneID: "pane-42", terminalID: "terminal", workspaceID: "missing", tabID: "missing:tab",
            focused: false, label: nil, agent: "pi", title: nil, displayAgent: "test-agent",
            agentStatus: .blocked, revision: 1
        )
        let fallback = try XCTUnwrap(HerdrBackend.row(for: fallbackPane, sessionID: .default))

        XCTAssertEqual(singleTab.visibleLabel, "bin · test-agent")
        XCTAssertEqual(multiTab.visibleLabel, "workspace · tab · test-agent")
        XCTAssertEqual(duplicate.visibleLabel, "test-agent")
        XCTAssertEqual(fallback.visibleLabel, "pane-42 · test-agent")
    }

    func testSubtitlesPreservePaneLabelAndDisplayAgentPreference() throws {
        let paneLabel = PaneInfo(
            paneID: "p1", terminalID: "t", workspaceID: "w", tabID: "tab", focused: false,
            label: "test-agent", agent: "pi", title: nil, displayAgent: nil, agentStatus: .blocked, revision: 1
        )
        let displayAgent = PaneInfo(
            paneID: "p2", terminalID: "t", workspaceID: "w", tabID: "tab", focused: false,
            label: "test-agent", agent: "pi", title: nil, displayAgent: "Pi Display", agentStatus: .working, revision: 1
        )
        XCTAssertEqual(try XCTUnwrap(HerdrBackend.row(for: paneLabel, sessionID: .default)).subtitle,
                       "blocked · test-agent")
        XCTAssertEqual(try XCTUnwrap(HerdrBackend.row(for: displayAgent, sessionID: .default)).subtitle,
                       "working · Pi Display")
    }

    func testJoinedLabelFallsBackThroughPaneTitleLabelAndID() {
        let rows = HerdrBackend.makeSnapshot(PresentationSnapshot(panes: [
            herdrPane("title", .done, title: "Pane title", workspaceID: "missing", tabID: "missing:tab"),
            herdrPane("label", .done, label: "Pane label", workspaceID: "missing", tabID: "missing:tab"),
            herdrPane("final-id", .done, workspaceID: "missing", tabID: "missing:tab")
        ], workspaces: [], tabs: []), sessionID: .default).rows

        XCTAssertEqual(rows.map(\.displayLabel), ["Pane title", "Pane label", "final-id"])
    }

    func testDistinctSnapshotTabsMakeWorkspaceMultiTabWhenCountIsStale() {
        let rows = HerdrBackend.makeSnapshot(PresentationSnapshot(
            panes: [herdrPane("server", .working, workspaceID: "w", tabID: "t2")],
            workspaces: [herdrWorkspace("w", label: "Herdr Menubar", tabCount: 1)],
            tabs: [herdrTab("t1", workspaceID: "w", label: "shell"), herdrTab("t2", workspaceID: "w", label: "server")]
        ), sessionID: .default).rows

        XCTAssertEqual(rows.first?.displayLabel, "Herdr Menubar · server")
    }

    // MARK: Events and lifecycle

    func testSupervisorEventsMapOneToOneOntoBackendEvents() async {
        let fixture = HerdrBackendFixture()
        var events = await fixture.backend.events().makeAsyncIterator()
        await fixture.backend.start()
        let work = herdrDescriptor("work")
        let snapshot = herdrSnapshot([herdrPane("p", .blocked)])

        await fixture.supervisor.send(.discoverySnapshot([work]))
        await fixture.supervisor.send(.connected(work, snapshot))
        await fixture.supervisor.send(.snapshot(.named("work"), snapshot))
        await fixture.supervisor.send(.unavailable(.named("work"), "socket unavailable"))
        await fixture.supervisor.send(.removed(.named("work")))

        var received: [BackendEvent] = []
        for _ in 0..<5 {
            if let event = await events.next() { received.append(event) }
        }
        let key = AgentSessionKey(herdr: .named("work"))
        let descriptor = AgentSessionDescriptor(key: key, displayName: "work")
        let expected = HerdrBackend.makeSnapshot(snapshot, sessionID: .named("work"))
        XCTAssertEqual(received, [
            .discovery([descriptor]),
            .connected(descriptor, expected),
            .snapshot(key, expected),
            .sessionUnavailable(key, "socket unavailable"),
            .removed(key)
        ])
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["events", "start"])
        await fixture.backend.stop()
    }

    func testRemovalForgetsGhosttyStateOnlyForForwardedSessionsAndOnlyOnce() async {
        let fixture = HerdrBackendFixture()
        var events = await fixture.backend.events().makeAsyncIterator()
        await fixture.backend.start()

        await fixture.supervisor.send(.discoverySnapshot([herdrDescriptor("work")]))
        await fixture.supervisor.send(.removed(.named("work")))
        await fixture.supervisor.send(.removed(.named("work")))
        await fixture.supervisor.send(.removed(.named("never-seen")))
        for _ in 0..<4 { _ = await events.next() }

        XCTAssertEqual(fixture.focuser.forgotten, [.named("work")])
        await fixture.backend.stop()
    }

    func testDisabledHerdrEmitsHiddenAndNeverStartsSupervisor() async {
        let fixture = HerdrBackendFixture(enabledBackends: ["rex"])
        var events = await fixture.backend.events().makeAsyncIterator()

        await fixture.backend.start()

        let first = await events.next()
        XCTAssertEqual(first, .backendHidden)
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["events"])
        await fixture.backend.stop()
    }

    func testStopTerminatesSupervisorStreamBeforeStoppingSupervisor() async {
        let fixture = HerdrBackendFixture()
        _ = await fixture.backend.events()
        await fixture.backend.start()

        await fixture.backend.stop()

        let sawTerminated = await fixture.supervisor.stopSawTerminatedStream
        let actions = await fixture.supervisor.actions
        XCTAssertTrue(sawTerminated)
        XCTAssertEqual(actions, ["events", "start", "stop"])
    }

    // MARK: Selection

    func testFocusServerWrapsFailureWithSessionNameWording() async {
        let fixture = HerdrBackendFixture(
            focusError: HerdrAPIError(code: "pane_not_found", message: "Pane no longer exists")
        )
        do {
            try await fixture.backend.focusServer(herdrTarget(.named("work"), "p"))
            XCTFail("Expected focus failure")
        } catch let error as FocusError {
            XCTAssertEqual(error, .failed("Could not focus pane in work: Pane no longer exists"))
            XCTAssertEqual(error.localizedDescription, "Could not focus pane in work: Pane no longer exists")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["focus:work:p"])
    }

    func testFocusServerFocusesExactSessionAndPane() async throws {
        let fixture = HerdrBackendFixture()
        try await fixture.backend.focusServer(herdrTarget(.default, "pane-1"))
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["focus:Default:pane-1"])
    }

    func testGhosttyActivationFocusesExactSessionAndReportsPartialFocus() async {
        let fixture = HerdrBackendFixture(terminal: GhosttyControlConstants.bundleIdentifier)
        let success = await fixture.backend.activate(herdrTarget(.named("work"), "p"))
        XCTAssertNil(success)

        fixture.focuser.error = .noAttachedClient
        let partial = await fixture.backend.activate(herdrTarget(.named("work"), "p"))

        XCTAssertEqual(partial, "Focused the pane in work, but no attached Ghostty surface was found.")
        XCTAssertEqual(fixture.focuser.focused, [.named("work"), .named("work")])
        XCTAssertTrue(fixture.activator.activated.isEmpty)
    }

    func testOtherTerminalsUseGenericActivationAndReportItsError() async {
        let fixture = HerdrBackendFixture(terminal: "com.apple.Terminal")
        let success = await fixture.backend.activate(herdrTarget(.default, "p"))
        XCTAssertNil(success)

        fixture.activator.error = HerdrBackendTestError.activation
        let failure = await fixture.backend.activate(herdrTarget(.default, "p"))

        XCTAssertEqual(failure, "activation failed")
        XCTAssertEqual(fixture.activator.activated, ["com.apple.Terminal", "com.apple.Terminal"])
        XCTAssertTrue(fixture.focuser.focused.isEmpty)
    }

    func testRefreshAndRetryDelegateToSupervisor() async {
        let fixture = HerdrBackendFixture()
        await fixture.backend.refreshAfterSelection(herdrTarget(.named("work"), "p"))
        await fixture.backend.retryUnavailable()
        await fixture.backend.markSeen(SeenToken(marks: ["ignored"]))
        await fixture.backend.clearFinished()
        let actions = await fixture.supervisor.actions
        XCTAssertEqual(actions, ["refresh:work", "retry"])
    }

    func testCompareSessionsKeepsTodaysComparator() {
        let fixture = HerdrBackendFixture()
        let sessions = [
            AgentSessionDescriptor(herdr: herdrDescriptor("zulu")),
            AgentSessionDescriptor(herdr: herdrDescriptor("alpha")),
            AgentSessionDescriptor(herdr: SessionDescriptor(id: .default, socketURL: URL(fileURLWithPath: "/tmp/d.sock"))),
            AgentSessionDescriptor(herdr: herdrDescriptor("Alpha"))
        ]

        let sorted = sessions.sorted(by: fixture.backend.compareSessions)

        XCTAssertEqual(sorted.map(\.displayName), ["Default", "Alpha", "alpha", "zulu"])
        XCTAssertEqual(fixture.backend.kind, .herdr)
    }
}

@MainActor
private struct HerdrBackendFixture {
    let supervisor: HerdrBackendSupervisor
    let focuser: HerdrBackendGhosttyFocuser
    let activator: HerdrBackendActivator
    let backend: HerdrBackend

    init(
        focusError: (any Error)? = nil,
        terminal: String = GhosttyControlConstants.bundleIdentifier,
        enabledBackends: [String]? = nil
    ) {
        supervisor = HerdrBackendSupervisor(focusError: focusError)
        focuser = HerdrBackendGhosttyFocuser()
        activator = HerdrBackendActivator()
        let defaults = UserDefaults(suiteName: "dev.herdr.menubar.herdr-backend-tests.\(UUID().uuidString)")!
        if let enabledBackends {
            defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey)
        }
        let preferences = Preferences(defaults: defaults)
        preferences.selectedTerminalBundleIdentifier = terminal
        backend = HerdrBackend(
            supervisor: supervisor,
            terminalActivator: activator,
            ghosttyFocuser: focuser,
            preferences: preferences
        )
    }
}

private final class HerdrBackendTerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private actor HerdrBackendSupervisor: SessionSupervising {
    private var continuation: AsyncStream<SessionSupervisorEvent>.Continuation?
    private let termination = HerdrBackendTerminationFlag()
    private let focusError: (any Error)?
    private(set) var actions: [String] = []
    private(set) var stopSawTerminatedStream = false

    init(focusError: (any Error)?) { self.focusError = focusError }

    func events() -> AsyncStream<SessionSupervisorEvent> {
        actions.append("events")
        let (stream, continuation) = AsyncStream<SessionSupervisorEvent>.makeStream()
        let termination = self.termination
        continuation.onTermination = { _ in termination.set() }
        self.continuation = continuation
        return stream
    }

    func start() { actions.append("start") }

    func stop() {
        stopSawTerminatedStream = termination.isSet
        actions.append("stop")
        continuation?.finish()
    }

    func retryUnavailable() { actions.append("retry") }

    func focus(sessionID: SessionID, paneID: String) throws -> PaneInfo {
        actions.append("focus:\(sessionID.displayName):\(paneID)")
        if let focusError { throw focusError }
        return herdrPane(paneID, .idle)
    }

    func setClientWindowTitle(sessionID: SessionID, title: String) -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "set")
    }

    func clearClientWindowTitle(sessionID: SessionID, timeout: Duration) -> ClientWindowTitleResult {
        ClientWindowTitleResult(type: "client_window_title", changed: true, reason: "cleared")
    }

    func refresh(sessionID: SessionID) { actions.append("refresh:\(sessionID.displayName)") }

    func send(_ event: SessionSupervisorEvent) { continuation?.yield(event) }
}

@MainActor
private final class HerdrBackendGhosttyFocuser: GhosttySessionFocusing {
    private(set) var focused: [SessionID] = []
    private(set) var forgotten: [SessionID] = []
    var error: GhosttyFocusError?

    func focusAttachedClient(sessionID: SessionID) async throws {
        focused.append(sessionID)
        if let error { throw error }
    }

    func forget(sessionID: SessionID) { forgotten.append(sessionID) }
}

@MainActor
private final class HerdrBackendActivator: TerminalActivating {
    private(set) var activated: [String] = []
    var error: (any Error)?

    func activate(bundleIdentifier: String) async throws {
        activated.append(bundleIdentifier)
        if let error { throw error }
    }
}

private enum HerdrBackendTestError: LocalizedError {
    case activation
    var errorDescription: String? { "activation failed" }
}

private func herdrTarget(_ sessionID: SessionID, _ paneID: String) -> AgentTarget {
    AgentTarget(session: AgentSessionKey(herdr: sessionID), paneID: paneID)
}

private func herdrDescriptor(_ name: String) -> SessionDescriptor {
    SessionDescriptor(id: .named(name), socketURL: URL(fileURLWithPath: "/tmp/\(name).sock"))
}

private func herdrSnapshot(_ panes: [PaneInfo]) -> PresentationSnapshot {
    PresentationSnapshot(panes: panes, workspaces: [], tabs: [])
}

private func herdrPane(
    _ id: String,
    _ status: AgentStatus,
    title: String? = nil,
    label: String? = nil,
    workspaceID: String = "workspace",
    tabID: String = "tab"
) -> PaneInfo {
    PaneInfo(
        paneID: id, terminalID: "terminal-\(id)", workspaceID: workspaceID, tabID: tabID,
        focused: false, label: label, agent: "claude", title: title, displayAgent: "Claude",
        agentStatus: status, revision: 1
    )
}

private func herdrWorkspace(_ id: String, label: String, tabCount: Int) -> WorkspaceInfo {
    WorkspaceInfo(
        workspaceID: id, number: 1, label: label, focused: false, paneCount: 1,
        tabCount: tabCount, activeTabID: "\(id):tab", agentStatus: .working
    )
}

private func herdrTab(_ id: String, workspaceID: String, label: String) -> TabInfo {
    TabInfo(
        tabID: id, workspaceID: workspaceID, number: 1, label: label, focused: false,
        paneCount: 1, agentStatus: .working
    )
}
```

- [ ] **Step 2: Register the files in the Xcode project**

Edit `HerdrMenubar.xcodeproj/project.pbxproj`:

1. After `		B10000000000000000000002 /* SessionSupervisor.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000001 /* SessionSupervisor.swift */; };` insert
   ```
   		BB0000000000000000000003 /* HerdrBackend.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000013 /* HerdrBackend.swift */; };
   		BB0000000000000000000004 /* HerdrBackendTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000014 /* HerdrBackendTests.swift */; };
   ```
2. After `		B10000000000000000000001 /* SessionSupervisor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SessionSupervisor.swift; sourceTree = "<group>"; };` insert
   ```
   		BB0000000000000000000013 /* HerdrBackend.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HerdrBackend.swift; sourceTree = "<group>"; };
   		BB0000000000000000000014 /* HerdrBackendTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HerdrBackendTests.swift; sourceTree = "<group>"; };
   ```
3. In the `Herdr` group, after `				B10000000000000000000001 /* SessionSupervisor.swift */,` insert `				BB0000000000000000000013 /* HerdrBackend.swift */,`
   In the `HerdrMenubarTests` group, after `				BB0000000000000000000012 /* AgentBackendTypesTests.swift */,` insert `				BB0000000000000000000014 /* HerdrBackendTests.swift */,`
4. In the app Sources phase, after `				B10000000000000000000002 /* SessionSupervisor.swift in Sources */,` insert `				BB0000000000000000000003 /* HerdrBackend.swift in Sources */,`
   In the test Sources phase, after `				BB0000000000000000000002 /* AgentBackendTypesTests.swift in Sources */,` insert `				BB0000000000000000000004 /* HerdrBackendTests.swift in Sources */,`

Run: `touch HerdrMenubar/Herdr/HerdrBackend.swift && xcodebuild -list -project HerdrMenubar.xcodeproj`
Expected: target list prints.

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/HerdrBackendTests`
Expected: FAIL — `cannot find 'HerdrBackend' in scope`.

- [ ] **Step 4: Implement**

Write `HerdrMenubar/Herdr/HerdrBackend.swift`:

```swift
import Foundation
import OSLog

/// The Herdr session supervisor presented as one agent backend.
@MainActor
final class HerdrBackend: AgentBackend {
    nonisolated var kind: BackendKind { .herdr }

    private let supervisor: any SessionSupervising
    private let terminalActivator: any TerminalActivating
    private let ghosttyFocuser: any GhosttySessionFocusing
    private let preferences: Preferences
    private var continuation: AsyncStream<BackendEvent>.Continuation?
    private var forwardTask: Task<Void, Never>?
    private var lifecycle: UInt64 = 0
    /// Sessions forwarded as known; Ghostty state is forgotten only for these.
    private var knownSessions: Set<SessionID> = []

    init(
        supervisor: any SessionSupervising,
        terminalActivator: any TerminalActivating,
        ghosttyFocuser: any GhosttySessionFocusing,
        preferences: Preferences
    ) {
        self.supervisor = supervisor
        self.terminalActivator = terminalActivator
        self.ghosttyFocuser = ghosttyFocuser
        self.preferences = preferences
    }

    func events() async -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream<BackendEvent>.makeStream()
        let owningLifecycle = lifecycle
        let source = await supervisor.events()
        guard owningLifecycle == lifecycle else {
            continuation.finish()
            return stream
        }
        forwardTask?.cancel()
        self.continuation?.finish()
        self.continuation = continuation
        forwardTask = Task { [weak self] in
            for await event in source {
                guard !Task.isCancelled else { return }
                self?.forward(event)
            }
        }
        return stream
    }

    func start() async {
        guard preferences.enabledBackends.contains(.herdr) else {
            continuation?.yield(.backendHidden)
            return
        }
        await supervisor.start()
    }

    func stop() async {
        lifecycle &+= 1
        let task = forwardTask
        forwardTask = nil
        continuation?.finish()
        continuation = nil
        knownSessions.removeAll()
        task?.cancel()
        await task?.value
        await supervisor.stop()
    }

    func retryUnavailable() async {
        await supervisor.retryUnavailable()
    }

    func focusServer(_ target: AgentTarget) async throws {
        guard let sessionID = target.session.herdrSessionID else {
            throw FocusError.failed("Could not focus pane: \(target.session.rawID) is not a Herdr session")
        }
        do {
            _ = try await supervisor.focus(sessionID: sessionID, paneID: target.paneID)
        } catch {
            throw FocusError.failed(
                "Could not focus pane in \(sessionID.displayName): \(error.localizedDescription)"
            )
        }
    }

    func activate(_ target: AgentTarget) async -> String? {
        guard let sessionID = target.session.herdrSessionID else { return nil }
        let bundleIdentifier = preferences.selectedTerminalBundleIdentifier
        if bundleIdentifier == GhosttyControlConstants.bundleIdentifier {
            do {
                try await ghosttyFocuser.focusAttachedClient(sessionID: sessionID)
                return nil
            } catch {
                AppLog.systemActions.error(
                    "Ghostty session focus failed: \(error.localizedDescription, privacy: .private)"
                )
                return Self.ghosttyFocusMessage(error, sessionName: sessionID.displayName)
            }
        }
        do {
            try await terminalActivator.activate(bundleIdentifier: bundleIdentifier)
            return nil
        } catch {
            AppLog.systemActions.error(
                "Terminal activation failed: \(error.localizedDescription, privacy: .private)"
            )
            return error.localizedDescription
        }
    }

    func refreshAfterSelection(_ target: AgentTarget) async {
        guard let sessionID = target.session.herdrSessionID else { return }
        await supervisor.refresh(sessionID: sessionID)
    }

    func markSeen(_ token: SeenToken) async {}

    func clearFinished() async {}

    nonisolated func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        guard let lhsID = lhs.key.herdrSessionID, let rhsID = rhs.key.herdrSessionID else {
            return lhs.key.rawID < rhs.key.rawID
        }
        return Self.sessionOrder(lhsID, rhsID)
    }
}

extension HerdrBackend {
    nonisolated static func makeSnapshot(_ snapshot: PresentationSnapshot, sessionID: SessionID) -> BackendSnapshot {
        let workspacesByID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0) })
        var tabIDsByWorkspace: [String: Set<String>] = [:]
        for tab in snapshot.tabs {
            tabIDsByWorkspace[tab.workspaceID, default: []].insert(tab.tabID)
        }
        for pane in snapshot.panes {
            tabIDsByWorkspace[pane.workspaceID, default: []].insert(pane.tabID)
        }

        var rows: [AgentRow] = []
        // The last occurrence in an authoritative snapshot wins for a duplicate pane ID,
        // including occurrences that produce no row.
        var latestByPaneID: [String: AgentRow?] = [:]
        for pane in snapshot.panes {
            let workspace = workspacesByID[pane.workspaceID]
            let isMultiTab = (workspace?.tabCount ?? 0) > 1
                || (tabIDsByWorkspace[pane.workspaceID]?.count ?? 0) > 1
            let row = row(
                for: pane,
                sessionID: sessionID,
                workspace: workspace,
                tab: tabsByID[pane.tabID],
                workspaceIsMultiTab: isMultiTab
            )
            if let row { rows.append(row) }
            latestByPaneID[pane.paneID] = .some(row)
        }

        let attention = latestByPaneID.values
            .compactMap { $0 }
            .sorted(by: AgentRow.labelOrder)
            .compactMap { row -> AttentionRecord? in
                guard case .attention(let state) = row.state else { return nil }
                return AttentionRecord(
                    target: row.target,
                    recordID: "",
                    epoch: 0,
                    state: state,
                    visibleLabel: row.visibleLabel,
                    message: nil
                )
            }
        return BackendSnapshot(rows: rows, attention: attention)
    }

    nonisolated static func row(
        for pane: PaneInfo,
        sessionID: SessionID,
        workspace: WorkspaceInfo? = nil,
        tab: TabInfo? = nil,
        workspaceIsMultiTab: Bool = false
    ) -> AgentRow? {
        let state: RowState
        switch pane.agentStatus {
        case .blocked: state = .attention(.blocked)
        case .done: state = .attention(.done)
        case .working: state = .working
        case .idle, .unknown: return nil
        }
        let agentLabel = pane.agentLabel
        return AgentRow(
            target: AgentTarget(session: AgentSessionKey(herdr: sessionID), paneID: pane.paneID),
            displayLabel: displayLabel(
                pane: pane,
                workspace: workspace,
                tab: tab,
                workspaceIsMultiTab: workspaceIsMultiTab
            ),
            agentLabel: agentLabel,
            state: state,
            subtitle: "\(pane.agentStatus.rawValue) · \(agentLabel)",
            seenToken: nil
        )
    }

    nonisolated static func sessionOrder(_ lhs: SessionID, _ rhs: SessionID) -> Bool {
        switch (lhs, rhs) {
        case (.default, .default): return false
        case (.default, _): return true
        case (_, .default): return false
        case (.named(let lhsName), .named(let rhsName)):
            let locale = Locale(identifier: "en_US_POSIX")
            let lhsFolded = lhsName.folding(options: [.caseInsensitive], locale: locale)
            let rhsFolded = rhsName.folding(options: [.caseInsensitive], locale: locale)
            return lhsFolded == rhsFolded ? lhsName < rhsName : lhsFolded < rhsFolded
        }
    }

    nonisolated static func ghosttyFocusMessage(_ error: any Error, sessionName: String) -> String {
        let prefix = "Focused the pane in \(sessionName), but "
        switch error as? GhosttyFocusError {
        case .noAttachedClient, .lookupTimedOut:
            return prefix + "no attached Ghostty surface was found."
        case .unsupportedHerdr:
            return prefix + "this Herdr session must be updated for Ghostty surface focus."
        case .markerCleanupFailed:
            return prefix + "the temporary Ghostty focus marker could not be cleared."
        case .ghosttyUnavailable:
            return prefix + "Ghostty is not running."
        case .unsupportedGhostty:
            return prefix + "Ghostty 1.4.0 or later with Apple Event support is required."
        case .automationDenied:
            return prefix + "Automation permission to control Ghostty was denied. "
                + "Allow Herdr Menubar in System Settings > Privacy & Security > Automation."
        case .targetGone:
            return prefix + "the attached Ghostty surface or process disappeared."
        case .ambiguousMarker:
            return prefix + "more than one Ghostty surface matched the focus marker."
        case .ghosttyControlFailed, .none:
            return prefix + "Ghostty could not be controlled."
        }
    }

    private nonisolated static func displayLabel(
        pane: PaneInfo,
        workspace: WorkspaceInfo?,
        tab: TabInfo?,
        workspaceIsMultiTab: Bool
    ) -> String {
        if let workspace, !workspace.label.isEmpty {
            if workspaceIsMultiTab, let tab, !tab.label.isEmpty {
                return "\(workspace.label) · \(tab.label)"
            }
            return workspace.label
        }
        return pane.displayLabel
    }
}

private extension HerdrBackend {
    func forward(_ event: SessionSupervisorEvent) {
        guard let continuation else { return }
        switch event {
        case .discoverySnapshot(let descriptors):
            knownSessions.formUnion(descriptors.map(\.id))
            continuation.yield(.discovery(descriptors.map(AgentSessionDescriptor.init(herdr:))))
        case .connected(let descriptor, let snapshot):
            knownSessions.insert(descriptor.id)
            continuation.yield(.connected(
                AgentSessionDescriptor(herdr: descriptor),
                Self.makeSnapshot(snapshot, sessionID: descriptor.id)
            ))
        case .snapshot(let sessionID, let snapshot):
            continuation.yield(.snapshot(
                AgentSessionKey(herdr: sessionID),
                Self.makeSnapshot(snapshot, sessionID: sessionID)
            ))
        case .unavailable(let sessionID, let message):
            continuation.yield(.sessionUnavailable(AgentSessionKey(herdr: sessionID), message))
        case .removed(let sessionID):
            if knownSessions.remove(sessionID) != nil {
                ghosttyFocuser.forget(sessionID: sessionID)
            }
            continuation.yield(.removed(AgentSessionKey(herdr: sessionID)))
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/HerdrBackendTests -only-testing:HerdrMenubarTests/AgentStoreTests`
Expected: PASS (`AgentStoreTests` is untouched and still green).

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Herdr/HerdrBackend.swift HerdrMenubarTests/HerdrBackendTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: add HerdrBackend wrapping the session supervisor"
```

---

### Task 5: `SelectionTarget` migration and notification payload v2

**Files:**
- Modify: `HerdrMenubar/Notifications/NotificationModels.swift`, `HerdrMenubar/Notifications/LatestNotificationTargetStore.swift`, `HerdrMenubar/Notifications/NativeNotificationService.swift`, `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift`, `HerdrMenubar/Shortcuts/GlobalShortcutController.swift`, `HerdrMenubar/App/ApplicationRuntime.swift`, `HerdrMenubar/Menu/StatusMenuPresentation.swift`, `HerdrMenubar/Status/AgentStore.swift`
- Create: `HerdrMenubarTests/BackendTestSupport.swift`
- Modify tests: `AgentStoreTests`, `MultiSessionIntegrationTests`, `AttentionNotificationCoordinatorTests`, `NativeNotificationServiceTests`, `GlobalShortcutControllerTests`, `LatestNotificationTargetStoreTests`, `StatusMenuPresentationTests`, `ApplicationRuntimeTests`, `StatusItemControllerTests`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SelectionTarget`, `SelectionTarget.herdr(_:paneID:)`, `AgentSessionKey(herdr:)`, `herdrSessionID`, `BackendKind(rawValue:)` (Task 1).
- Produces:
  - `NotificationSelectionTarget` no longer exists. Every former use is `SelectionTarget`: `NotificationResponseSubscription.Element`, `AttentionNotificationEvent.target`, `LatestNotificationTargetRecording.record/latest`, `GlobalShortcutController.selectTarget`, `ApplicationRuntimeDependencies.selectTarget`, `ApplicationRuntime.receiveFocusLatestShortcut(_:)`, `StatusMenuNode.agent(target:)`, `StatusMenuAction.select(_:)`, `AgentStore.select(_:)`.
  - `NativeNotificationService.payload(for: SelectionTarget) -> [AnyHashable: Any]` writes version 2.
  - `NativeNotificationService.decodeTarget(_:) -> SelectionTarget?` accepts version 1 (Herdr keys only; display name = `SessionID.displayName`) and version 2 (dispatch on `backend`).
  - Test shims in `BackendTestSupport.swift`: `AgentSessionKey.default`, `AgentSessionKey.named(_:)`, `SelectionTarget.sessionID` (Herdr only), `SelectionTarget.paneID`.

- [ ] **Step 1: Create the test support file and register it**

Create `HerdrMenubarTests/BackendTestSupport.swift`:

```swift
import Foundation
@testable import HerdrMenubar

// Test-only shims that keep Herdr-shaped tests readable after the backend migration.

extension AgentSessionKey {
    static var `default`: AgentSessionKey { AgentSessionKey(herdr: .default) }
    static func named(_ name: String) -> AgentSessionKey { AgentSessionKey(herdr: .named(name)) }
}

extension SelectionTarget {
    /// Herdr targets only.
    var sessionID: SessionID { target.session.herdrSessionID! }
    var paneID: String { target.paneID }
}
```

Register it in `HerdrMenubar.xcodeproj/project.pbxproj`:

1. After the `BB0000000000000000000004 /* HerdrBackendTests.swift in Sources */ = {isa = PBXBuildFile; …};` line insert
   `		BB0000000000000000000005 /* BackendTestSupport.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000015 /* BackendTestSupport.swift */; };`
2. After the `BB0000000000000000000014 /* HerdrBackendTests.swift */ = {isa = PBXFileReference; …};` line insert
   `		BB0000000000000000000015 /* BackendTestSupport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BackendTestSupport.swift; sourceTree = "<group>"; };`
3. In the `HerdrMenubarTests` group, after `				BB0000000000000000000014 /* HerdrBackendTests.swift */,` insert `				BB0000000000000000000015 /* BackendTestSupport.swift */,`
4. In the test Sources phase, after `				BB0000000000000000000004 /* HerdrBackendTests.swift in Sources */,` insert `				BB0000000000000000000005 /* BackendTestSupport.swift in Sources */,`

- [ ] **Step 2: Rewrite test references mechanically, then add the new payload tests**

Run (from the repository root):

```bash
perl -0pi -e 's/NotificationSelectionTarget\(\s*sessionID:\s*/SelectionTarget.herdr(/g' HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/MultiSessionIntegrationTests.swift HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift HerdrMenubarTests/NativeNotificationServiceTests.swift HerdrMenubarTests/GlobalShortcutControllerTests.swift HerdrMenubarTests/LatestNotificationTargetStoreTests.swift HerdrMenubarTests/StatusMenuPresentationTests.swift HerdrMenubarTests/ApplicationRuntimeTests.swift HerdrMenubarTests/StatusItemControllerTests.swift && perl -pi -e 's/\bNotificationSelectionTarget\b/SelectionTarget/g' HerdrMenubarTests/*.swift
```

This turns `NotificationSelectionTarget(sessionID: X, paneID: Y)` (including multi-line forms) into `SelectionTarget.herdr(X, paneID: Y)` and every remaining type mention into `SelectionTarget`.

Run: `grep -rn "NotificationSelectionTarget" HerdrMenubarTests`
Expected: no output.

In `HerdrMenubarTests/NativeNotificationServiceTests.swift`:

Replace the four version/kind assertions at the end of `testDeliveryBuildsUniqueSilentRequestsWithVersionedNamedTarget` with:

```swift
        XCTAssertEqual(requests[0].content.userInfo["version"] as? Int, 2)
        XCTAssertEqual(requests[0].content.userInfo["backend"] as? String, "herdr")
        XCTAssertEqual(requests[0].content.userInfo["session_display_name"] as? String, "work")
        XCTAssertEqual(requests[0].content.userInfo["session_kind"] as? String, "named")
        XCTAssertEqual(requests[0].content.userInfo["session_name"] as? String, "work")
        XCTAssertEqual(requests[0].content.userInfo["pane_id"] as? String, "pane-1")
        XCTAssertNil(requests[0].content.userInfo["rex_session_id"])
```

Replace `testDefaultAndNamedPayloadsRoundTripExactly` with:

```swift
    func testDefaultNamedAndNamedDefaultPayloadsRoundTripAsVersionTwo() {
        let targets = [
            SelectionTarget.herdr(.default, paneID: "default-pane"),
            SelectionTarget.herdr(.named("work"), paneID: "named-pane"),
            SelectionTarget.herdr(.named("default"), paneID: "named-default-pane")
        ]

        for target in targets {
            let payload = NativeNotificationService.payload(for: target)
            XCTAssertEqual(payload["version"] as? Int, 2)
            let decoded = NativeNotificationService.decodeTarget(payload)
            XCTAssertEqual(decoded, target)
            XCTAssertEqual(decoded?.target, target.target)
            XCTAssertEqual(decoded?.sessionDisplayName, target.sessionDisplayName)
        }

        let defaultPayload = NativeNotificationService.payload(for: targets[0])
        XCTAssertEqual(defaultPayload["session_kind"] as? String, "default")
        XCTAssertNil(defaultPayload["session_name"])
        let namedDefault = NativeNotificationService.decodeTarget(
            NativeNotificationService.payload(for: targets[2])
        )
        XCTAssertNotEqual(namedDefault, SelectionTarget.herdr(.default, paneID: "named-default-pane"))
    }

    func testVersionOnePayloadDecodesThroughHerdrPath() {
        let named: [AnyHashable: Any] = [
            "version": 1, "session_kind": "named", "session_name": "work", "pane_id": "p1"
        ]
        let decoded = NativeNotificationService.decodeTarget(named)
        XCTAssertEqual(decoded, SelectionTarget.herdr(.named("work"), paneID: "p1"))
        XCTAssertEqual(decoded?.sessionDisplayName, "work")
        XCTAssertEqual(NativeNotificationService.decodeTarget(validPayload(paneID: "p2"))?.sessionDisplayName, "Default")
    }

    func testVersionTwoRexPayloadDecodesToRexTarget() {
        let payload: [AnyHashable: Any] = [
            "version": 2, "backend": "rex", "session_display_name": "fix-playback",
            "pane_id": "block-7", "rex_session_id": "sess-1"
        ]
        let decoded = NativeNotificationService.decodeTarget(payload)
        XCTAssertEqual(decoded?.target, AgentTarget(
            session: AgentSessionKey(backend: .rex, rawID: "sess-1"), paneID: "block-7"
        ))
        XCTAssertEqual(decoded?.sessionDisplayName, "fix-playback")
        XCTAssertEqual(
            NativeNotificationService.payload(for: decoded!)["rex_session_id"] as? String, "sess-1"
        )
    }

    func testVersionTwoPayloadsWithUnknownBackendOrMissingIDsAreRejected() {
        XCTAssertNil(NativeNotificationService.decodeTarget([
            "version": 2, "backend": "wezterm", "pane_id": "p", "session_kind": "default"
        ]))
        XCTAssertNil(NativeNotificationService.decodeTarget([
            "version": 2, "backend": "rex", "pane_id": "p"
        ]))
        XCTAssertNil(NativeNotificationService.decodeTarget([
            "version": 2, "backend": "herdr", "pane_id": "p"
        ]))
        XCTAssertNil(NativeNotificationService.decodeTarget([
            "version": 2, "session_kind": "default", "pane_id": "p"
        ]))
    }
```

Replace `testPayloadVersionAcceptsOnlyIntegerOne` with:

```swift
    func testPayloadVersionAcceptsOnlyIntegerOneAndTwo() {
        let acceptedVersions: [Any] = [1, NSNumber(value: 1)]
        for version in acceptedVersions {
            var payload = validPayload(paneID: "accepted-integer")
            payload["version"] = version
            XCTAssertEqual(
                NativeNotificationService.decodeTarget(payload),
                SelectionTarget.herdr(.default, paneID: "accepted-integer")
            )
        }
        var versionTwo = validPayload(paneID: "accepted-two")
        versionTwo["version"] = NSNumber(value: 2)
        versionTwo["backend"] = "herdr"
        XCTAssertEqual(
            NativeNotificationService.decodeTarget(versionTwo),
            SelectionTarget.herdr(.default, paneID: "accepted-two")
        )

        let rejectedVersions: [Any] = [NSNumber(value: true), NSNumber(value: 1.0), NSNumber(value: 2.0), 3, 0]
        for version in rejectedVersions {
            var payload = validPayload(paneID: "rejected-number")
            payload["version"] = version
            payload["backend"] = "herdr"
            XCTAssertNil(NativeNotificationService.decodeTarget(payload))
        }
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/NativeNotificationServiceTests`
Expected: FAIL — compile errors such as `cannot convert value of type 'SelectionTarget' to expected argument type 'NotificationSelectionTarget'`.

- [ ] **Step 4: Migrate production types**

Delete `struct NotificationSelectionTarget` (lines 3–6) from `HerdrMenubar/Notifications/NotificationModels.swift`, then run:

```bash
perl -0pi -e 's/NotificationSelectionTarget\(\s*sessionID:\s*/SelectionTarget.herdr(/g' HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift HerdrMenubar/Menu/StatusMenuPresentation.swift && perl -pi -e 's/\bNotificationSelectionTarget\b/SelectionTarget/g' HerdrMenubar/Notifications/NotificationModels.swift HerdrMenubar/Notifications/LatestNotificationTargetStore.swift HerdrMenubar/Notifications/NativeNotificationService.swift HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift HerdrMenubar/Shortcuts/GlobalShortcutController.swift HerdrMenubar/App/ApplicationRuntime.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubar/Status/AgentStore.swift
```

After this, `AttentionNotificationCoordinator` builds `SelectionTarget.herdr(session.id, paneID: item.paneID)` and `StatusMenuPresentationBuilder` builds `SelectionTarget.herdr(item.sessionID, paneID: item.paneID)` (both carry `SessionID.displayName`, which equals today's Herdr session name).

In `HerdrMenubar/Notifications/NativeNotificationService.swift`, replace `private static let payloadVersion = 1` with:

```swift
    private static let payloadVersion = 2
    private static let supportedPayloadVersions: Set<Int> = [1, 2]
```

and replace `payload(for:)`, `decodeTarget(_:)` and `isSupportedPayloadVersion(_:)` with:

```swift
    static func payload(for target: SelectionTarget) -> [AnyHashable: Any] {
        let session = target.target.session
        var payload: [AnyHashable: Any] = [
            "version": payloadVersion,
            "backend": session.backend.rawValue,
            "session_display_name": target.sessionDisplayName,
            "pane_id": target.target.paneID
        ]
        switch session.backend {
        case .herdr:
            switch session.herdrSessionID {
            case .default?:
                payload["session_kind"] = "default"
            case .named(let name)?:
                payload["session_kind"] = "named"
                payload["session_name"] = name
            case nil:
                break
            }
        case .rex:
            payload["rex_session_id"] = session.rawID
        }
        return payload
    }

    static func decodeTarget(_ userInfo: [AnyHashable: Any]) -> SelectionTarget? {
        guard let version = supportedPayloadVersion(userInfo["version"]),
              let paneID = userInfo["pane_id"] as? String,
              !paneID.isEmpty else { return nil }
        guard version >= 2 else {
            return decodeHerdrTarget(userInfo, paneID: paneID, displayName: nil)
        }
        guard let backend = (userInfo["backend"] as? String).flatMap(BackendKind.init(rawValue:)) else {
            return nil
        }
        let displayName = (userInfo["session_display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch backend {
        case .herdr:
            return decodeHerdrTarget(userInfo, paneID: paneID, displayName: displayName)
        case .rex:
            guard let sessionID = userInfo["rex_session_id"] as? String, !sessionID.isEmpty else { return nil }
            return SelectionTarget(
                target: AgentTarget(session: AgentSessionKey(backend: .rex, rawID: sessionID), paneID: paneID),
                sessionDisplayName: displayName ?? sessionID
            )
        }
    }

    private static func decodeHerdrTarget(
        _ userInfo: [AnyHashable: Any],
        paneID: String,
        displayName: String?
    ) -> SelectionTarget? {
        guard let sessionKind = userInfo["session_kind"] as? String else { return nil }
        let sessionID: SessionID
        switch sessionKind {
        case "default":
            sessionID = .default
        case "named":
            guard let sessionName = userInfo["session_name"] as? String,
                  !sessionName.isEmpty else { return nil }
            sessionID = .named(sessionName)
        default:
            return nil
        }
        let target = SelectionTarget.herdr(sessionID, paneID: paneID)
        guard let displayName else { return target }
        return SelectionTarget(target: target.target, sessionDisplayName: displayName)
    }

    /// The payload version when it is an integer (not Bool or floating point) in `supportedPayloadVersions`.
    private static func supportedPayloadVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              supportedPayloadVersions.contains(number.intValue) else { return nil }
        return number.intValue
    }
```

In `HerdrMenubar/Status/AgentStore.swift` (still the pre-backend store), make the type compile against `SelectionTarget`:

Replace the `.connected` pending check

```swift
            if let pendingNotificationTarget,
               pendingNotificationTarget.sessionID == descriptor.id {
```
with
```swift
            if let pendingNotificationTarget,
               pendingNotificationTarget.target.session == AgentSessionKey(herdr: descriptor.id) {
```

Replace in `.removed`

```swift
            if pendingNotificationTarget?.sessionID == id {
```
with
```swift
            if pendingNotificationTarget?.target.session == AgentSessionKey(herdr: id) {
```

Replace `receiveNotificationTarget(_:generation:)` and `discardAbsentPendingTarget(discovered:)` with:

```swift
    func receiveNotificationTarget(
        _ target: SelectionTarget,
        generation: UUID
    ) {
        guard isRunning, eventGeneration == generation else { return }
        supersedeSelection()
        guard let sessionID = target.target.session.herdrSessionID else {
            pendingNotificationTarget = nil
            return
        }
        guard let state = sessions[sessionID] else {
            if hasCompletedDiscovery {
                pendingNotificationTarget = nil
                transientError = "\(target.sessionDisplayName) is unavailable"
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
            sessionID: sessionID,
            paneID: target.target.paneID,
            sessionName: state.descriptor.displayName
        ))
    }

    func discardAbsentPendingTarget(discovered: [SessionDescriptor]) {
        guard let pendingNotificationTarget,
              let pendingSessionID = pendingNotificationTarget.target.session.herdrSessionID,
              sessions[pendingSessionID] == nil,
              !discovered.contains(where: { $0.id == pendingSessionID }) else {
            return
        }
        self.pendingNotificationTarget = nil
        transientError = "\(pendingNotificationTarget.sessionDisplayName) is unavailable"
    }
```

Run: `grep -rn "NotificationSelectionTarget" HerdrMenubar HerdrMenubarTests`
Expected: no output.

- [ ] **Step 5: Run the affected suites**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests`
Expected: PASS (full suite; payload tests new, everything else unchanged in behaviour).

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar HerdrMenubarTests HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "refactor: replace NotificationSelectionTarget with SelectionTarget and write payload v2"
```

---

### Task 6: Coordinator keyed by `(AgentTarget, recordID)` with `(state, epoch)` and per-backend `notifyStates`

**Files:**
- Rewrite: `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift`
- Modify: `HerdrMenubar/Notifications/NotificationModels.swift` (`AttentionNotificationEvent`, `NotificationDeliveryPolicy`, `AttentionNotificationCoordinating`)
- Modify: `HerdrMenubar/Notifications/NativeNotificationService.swift` (title switch)
- Modify: `HerdrMenubar/Status/AgentStore.swift` (transitional coordinator calls and policy)
- Modify: `HerdrMenubarTests/BackendTestSupport.swift`
- Test: `HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift`, `HerdrMenubarTests/NativeNotificationServiceTests.swift`, `HerdrMenubarTests/AgentStoreTests.swift`, `HerdrMenubarTests/MultiSessionIntegrationTests.swift`, `HerdrMenubarTests/StatusMenuPresentationTests.swift`

**Interfaces:**
- Consumes: `AgentSessionDescriptor`, `AttentionRecord`, `AttentionState`, `BackendKind.defaultNotifyStates` (Task 1); `Preferences.notifyStates` (Task 2); `HerdrBackend.makeSnapshot` (Task 4); `SelectionTarget` (Task 5).
- Produces:
  - `protocol AttentionNotificationCoordinating: Sendable { func reconcile(session: AgentSessionDescriptor, records: [AttentionRecord], policy: NotificationDeliveryPolicy) async; func unavailable(session: AgentSessionKey) async; func remove(session: AgentSessionKey) async; func reset() async }`
  - `struct AttentionNotificationEvent { let target: SelectionTarget; let sessionName: String; let visibleLabel: String; let status: AttentionState }`
  - `struct NotificationDeliveryPolicy { notificationsEnabled; soundEnabled; notifyStates: [BackendKind: Set<AttentionState>]; init(notificationsEnabled:soundEnabled:notifyStates: = NotificationDeliveryPolicy.defaultNotifyStates) }`
  - Test shims: `func herdrRecords(_ session: SessionDescriptor, _ panes: [PaneInfo]) -> [AttentionRecord]` and `extension AttentionNotificationCoordinating { func reconcile(session: SessionDescriptor, items: [PaneInfo], policy:) async }`.

- [ ] **Step 1: Add test shims and migrate the existing coordinator tests**

Append to `HerdrMenubarTests/BackendTestSupport.swift`:

```swift
/// Herdr attention records for a pane list, exactly as `HerdrBackend` builds them.
func herdrRecords(_ session: SessionDescriptor, _ panes: [PaneInfo]) -> [AttentionRecord] {
    HerdrBackend.makeSnapshot(
        PresentationSnapshot(panes: panes, workspaces: [], tabs: []),
        sessionID: session.id
    ).attention
}

extension AttentionNotificationCoordinating {
    /// Herdr-shaped reconcile so pane-list tests express "Herdr exactly as today".
    func reconcile(
        session: SessionDescriptor,
        items: [PaneInfo],
        policy: NotificationDeliveryPolicy
    ) async {
        await reconcile(
            session: AgentSessionDescriptor(herdr: session),
            records: herdrRecords(session, items),
            policy: policy
        )
    }
}
```

In `HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift`, change the `item(_:_:_:title:)` helper to return the pane itself:

```swift
private func item(
    _ session: SessionDescriptor,
    _ paneID: String,
    _ status: AgentStatus,
    title: String? = nil
) -> PaneInfo {
    PaneInfo(
        paneID: paneID,
        terminalID: "terminal-\(paneID)",
        workspaceID: "workspace-\(paneID)",
        tabID: "tab-\(paneID)",
        focused: false,
        label: "Pi",
        agent: "pi",
        title: title ?? paneID,
        displayAgent: "Pi",
        agentStatus: status,
        revision: 1
    )
}
```

Then run:

```bash
perl -pi -e 's/\.(unavailable|remove)\(sessionID: (\w+)\.id\)/.$1(session: AgentSessionKey(herdr: $2.id))/g' HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift
```

Every existing coordinator test now runs Herdr panes through `HerdrBackend.makeSnapshot` and the new coordinator. They are the "Herdr exactly as today" gate: baseline silence, idle/unknown/working → attention delivers once, repeats silent, disappearance/reappearance, duplicates (last wins), label-ordered delivery with pane-ID tie-breaker, cancellation, sound, disabled delivery still advancing history, unavailable/remove/reset.

Append these record-level tests inside `AttentionNotificationCoordinatorTests`:

```swift
    func testEpochChangeRenotifiesEvenWhenStateRepeats() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error, .done])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .done)], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .done)], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 3, state: .done)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.done, .done])
    }

    func testStaleErrorThatStaysPresentNeverRenotifies() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error])
        let staleError = rexRecord(session, epoch: 1, state: .error)

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [staleError], policy: policy)
        await coordinator.reconcile(
            session: session,
            records: [staleError, rexRecord(session, id: "child", epoch: 2, state: .blocked)],
            policy: policy
        )
        await coordinator.reconcile(session: session, records: [staleError], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.error, .blocked])
    }

    func testDroppedAndRecreatedRecordRenotifies() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.error])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .error)], policy: policy)
        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 4, state: .error)], policy: policy)
        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 4, state: .error)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.error, .error, .error])
    }

    func testUncheckedStateUpdatesHistoryWithoutLaterReplay() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()

        await coordinator.reconcile(session: session, records: [], policy: rexPolicy([.blocked]))
        await coordinator.reconcile(
            session: session, records: [rexRecord(session, epoch: 1, state: .error)], policy: rexPolicy([.blocked])
        )
        await coordinator.reconcile(
            session: session, records: [rexRecord(session, epoch: 1, state: .error)], policy: rexPolicy([.blocked, .error])
        )
        await coordinator.reconcile(
            session: session, records: [rexRecord(session, epoch: 2, state: .error)], policy: rexPolicy([.blocked, .error])
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.error])
    }

    func testCandidatesDeliverInGivenOrderNotLabelOrder() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [
            rexRecord(session, block: "z", epoch: 1, state: .blocked, label: "Zulu"),
            rexRecord(session, block: "a", epoch: 2, state: .blocked, label: "Alpha")
        ], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["z", "a"])
        XCTAssertEqual(deliveries.map(\.event.sessionName), ["fix-playback", "fix-playback"])
        XCTAssertEqual(deliveries.map(\.event.target.sessionDisplayName), ["fix-playback", "fix-playback"])
    }

    func testFirstBlockedAfterEmptyConnectedBaselineNotifies() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error])

        await coordinator.reconcile(session: session, records: [], policy: policy)
        await coordinator.reconcile(session: session, records: [rexRecord(session, epoch: 1, state: .blocked)], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.status), [.blocked])
    }

    func testRestartReconciliationNotifiesOnlyChangedRecords() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = rexSession()
        let policy = rexPolicy([.blocked, .error])

        await coordinator.reconcile(session: session, records: [
            rexRecord(session, block: "b1", epoch: 1, state: .blocked),
            rexRecord(session, block: "b2", epoch: 2, state: .error)
        ], policy: policy)
        await coordinator.unavailable(session: session.key)
        await coordinator.reconcile(session: session, records: [
            rexRecord(session, block: "b1", epoch: 1, state: .blocked),
            rexRecord(session, block: "b2", epoch: 5, state: .error)
        ], policy: policy)

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["b2"])
    }

    func testHerdrNotifyStatesFilterHerdrDeliveries() async {
        let service = RecordingNotificationService()
        let coordinator = AttentionNotificationCoordinator(
            service: service, latestTargetRecorder: RecordingLatestNotificationTargetRecorder()
        )
        let session = descriptor("work")
        let policy = NotificationDeliveryPolicy(
            notificationsEnabled: true,
            soundEnabled: false,
            notifyStates: [.herdr: [.blocked], .rex: [.blocked, .error]]
        )

        await coordinator.reconcile(
            session: session, items: [item(session, "a", .working), item(session, "b", .working)], policy: policy
        )
        await coordinator.reconcile(
            session: session, items: [item(session, "a", .done), item(session, "b", .blocked)], policy: policy
        )

        let deliveries = await service.deliveries
        XCTAssertEqual(deliveries.map(\.event.target.paneID), ["b"])
    }
```

Add these helpers at the bottom of the file:

```swift
private func rexSession() -> AgentSessionDescriptor {
    AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s1"), displayName: "fix-playback")
}

private func rexRecord(
    _ session: AgentSessionDescriptor,
    block: String = "b1",
    id: String = "",
    epoch: Int,
    state: AttentionState,
    label: String = "Review · claude-code"
) -> AttentionRecord {
    AttentionRecord(
        target: AgentTarget(session: session.key, paneID: block),
        recordID: id,
        epoch: epoch,
        state: state,
        visibleLabel: label,
        message: nil
    )
}

private func rexPolicy(_ states: Set<AttentionState>) -> NotificationDeliveryPolicy {
    NotificationDeliveryPolicy(
        notificationsEnabled: true,
        soundEnabled: false,
        notifyStates: [.herdr: [.blocked, .done], .rex: states]
    )
}
```

In `HerdrMenubarTests/NativeNotificationServiceTests.swift`, add:

```swift
    func testErrorDeliveryUsesFailedTitle() async throws {
        let backend = FakeNotificationCenterBackend(settings: .authorized)
        let service = NativeNotificationService(backend: backend)
        _ = try await service.deliver(AttentionNotificationEvent(
            target: SelectionTarget.herdr(.default, paneID: "p"),
            sessionName: "Default",
            visibleLabel: "Label",
            status: .error
        ), sound: false)

        XCTAssertEqual(backend.addedRequests.first?.content.title, "Agent failed")
    }
```

- [ ] **Step 2: Update other coordinator conformers in tests**

`HerdrMenubarTests/AgentStoreTests.swift` — replace `RecordingAttentionCoordinator`'s stored types and the three protocol methods:

```swift
private actor RecordingAttentionCoordinator: AttentionNotificationCoordinating {
    struct Reconciliation: Sendable {
        let session: AgentSessionDescriptor
        let records: [AttentionRecord]
        let policy: NotificationDeliveryPolicy
    }

    private(set) var reconciliations: [Reconciliation] = []
    private(set) var unavailableSessionIDs: [AgentSessionKey] = []
    private(set) var removedSessionIDs: [AgentSessionKey] = []
    private(set) var resetCount = 0
    private let reconciliationSignal = AsyncCountSignal()
    private let unavailableSignal = AsyncCountSignal()
    private let removalSignal = AsyncCountSignal()

    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) async {
        reconciliations.append(Reconciliation(session: session, records: records, policy: policy))
        await reconciliationSignal.record()
    }

    func unavailable(session: AgentSessionKey) async {
        unavailableSessionIDs.append(session)
        await unavailableSignal.record()
    }

    func remove(session: AgentSessionKey) async {
        removedSessionIDs.append(session)
        await removalSignal.record()
    }
```
(keep `reset()`, the `waitFor…` helpers and `barrier()` unchanged).

In `testOnlyAcceptedFullSnapshotsReachNotificationCoordinatorInAuthoritativeOrder`, replace

```swift
        XCTAssertEqual(calls.map { $0.items.map(\.paneID) }, [
            ["idle", "unknown", "blocked"], ["working", "done"]
        ])
```
with
```swift
        XCTAssertEqual(calls.map { $0.records.map(\.target.paneID) }, [["blocked"], ["done"]])
        XCTAssertEqual(calls.map(\.session.key), [.named("work"), .named("work")])
```

Add a policy test to `AgentStoreTests`:

```swift
    func testNotificationPolicyCarriesStoredNotifyStates() async {
        let supervisor = FakeSessionSupervisor()
        let coordinator = RecordingAttentionCoordinator()
        let preferences = testPreferences()
        preferences.notificationsEnabled = true
        preferences.setNotifyStates([.blocked], for: .herdr)
        let store = makeStore(supervisor: supervisor, attentionCoordinator: coordinator, preferences: preferences)
        await store.start()

        await supervisor.send(.connected(workDescriptor, snapshot([pane("p", .blocked)])))
        await coordinator.waitForReconciliations(1)

        let policy = await coordinator.reconciliations.first?.policy
        XCTAssertEqual(policy?.notifyStates[.herdr], [.blocked])
        XCTAssertEqual(policy?.notifyStates[.rex], [.blocked, .error])
        await store.stop()
    }
```

`HerdrMenubarTests/StatusMenuPresentationTests.swift` — replace `PresentationAttentionCoordinator`:

```swift
private actor PresentationAttentionCoordinator: AttentionNotificationCoordinating {
    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) {}
    func unavailable(session: AgentSessionKey) {}
    func remove(session: AgentSessionKey) {}
    func reset() {}
}
```

`HerdrMenubarTests/MultiSessionIntegrationTests.swift`:

Replace `IntegrationAttentionCoordinator` with:

```swift
private actor IntegrationAttentionCoordinator: AttentionNotificationCoordinating {
    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) {}
    func unavailable(session: AgentSessionKey) {}
    func remove(session: AgentSessionKey) {}
    func reset() {}
}
```

In `IntegrationObservingAttentionCoordinator`, replace `reconcile`, `unavailable(sessionID:)` and `remove(sessionID:)` with (its internal maps stay keyed by `SessionID`):

```swift
    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) async {
        let sessionID = session.key.herdrSessionID!
        if reconcilePauses.remove(sessionID) != nil {
            do {
                try await waitForPauseRelease(for: sessionID)
            } catch {
                return
            }
        }
        await wrapped.reconcile(session: session, records: records, policy: policy)
        recordCompletion(for: sessionID, counts: &reconcileCompletions, waiters: &reconcileWaiters)
    }

    func unavailable(session: AgentSessionKey) async {
        await wrapped.unavailable(session: session)
    }

    func remove(session: AgentSessionKey) async {
        await wrapped.remove(session: session)
        recordCompletion(for: session.herdrSessionID!, counts: &removeCompletions, waiters: &removeWaiters)
    }
```

Then rewrite the direct pane-item reconcile calls:

```bash
perl -0pi -e 's/\[AgentMenuItem\(\s*session:\s*session,\s*pane:\s*(integrationPane\("[^"]*",\s*\.\w+\))\s*\)\]/[$1]/g' HerdrMenubarTests/MultiSessionIntegrationTests.swift
```

(`observer.reconcile(session: session, items: [], policy: …)` resolves to the shim and needs no edit.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/AttentionNotificationCoordinatorTests`
Expected: FAIL — `incorrect argument label in call (have 'session:records:policy:', expected 'session:items:policy:')`.

- [ ] **Step 4: Implement**

In `HerdrMenubar/Notifications/NotificationModels.swift`, replace `AttentionNotificationEvent`, `NotificationDeliveryPolicy` and `AttentionNotificationCoordinating` with:

```swift
struct AttentionNotificationEvent: Equatable, Sendable {
    let target: SelectionTarget
    let sessionName: String
    let visibleLabel: String
    let status: AttentionState
}
```

```swift
struct NotificationDeliveryPolicy: Equatable, Sendable {
    static let defaultNotifyStates: [BackendKind: Set<AttentionState>] = Dictionary(
        uniqueKeysWithValues: BackendKind.allCases.map { ($0, $0.defaultNotifyStates) }
    )

    let notificationsEnabled: Bool
    let soundEnabled: Bool
    let notifyStates: [BackendKind: Set<AttentionState>]

    init(
        notificationsEnabled: Bool,
        soundEnabled: Bool,
        notifyStates: [BackendKind: Set<AttentionState>] = NotificationDeliveryPolicy.defaultNotifyStates
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.soundEnabled = soundEnabled
        self.notifyStates = notifyStates
    }
}
```

```swift
protocol AttentionNotificationCoordinating: Sendable {
    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) async
    func unavailable(session: AgentSessionKey) async
    func remove(session: AgentSessionKey) async
    func reset() async
}
```

Replace `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift` with:

```swift
import OSLog

actor AttentionNotificationCoordinator: AttentionNotificationCoordinating {
    private struct RecordKey: Hashable {
        let target: AgentTarget
        let recordID: String
    }

    private struct RecordStamp: Equatable {
        let state: AttentionState
        let epoch: Int
    }

    private let service: any NativeNotificationServing
    private let latestTargetRecorder: any LatestNotificationTargetRecording
    private var baselinedSessions: Set<AgentSessionKey> = []
    private var history: [AgentSessionKey: [RecordKey: RecordStamp]] = [:]
    private var nextDeliveryOrdinal: UInt64 = 0

    init(
        service: any NativeNotificationServing,
        latestTargetRecorder: any LatestNotificationTargetRecording
    ) {
        self.service = service
        self.latestTargetRecorder = latestTargetRecorder
    }

    func reconcile(
        session: AgentSessionDescriptor,
        records: [AttentionRecord],
        policy: NotificationDeliveryPolicy
    ) async {
        // The last occurrence of a record key wins; delivery keeps first-occurrence order.
        var canonical: [RecordKey: AttentionRecord] = [:]
        for record in records {
            canonical[Self.key(record)] = record
        }
        var ordered: [AttentionRecord] = []
        var emitted: Set<RecordKey> = []
        for record in records {
            let key = Self.key(record)
            guard emitted.insert(key).inserted, let winner = canonical[key] else { continue }
            ordered.append(winner)
        }
        let current = canonical.mapValues { RecordStamp(state: $0.state, epoch: $0.epoch) }

        guard baselinedSessions.contains(session.key) else {
            baselinedSessions.insert(session.key)
            history[session.key] = current
            return
        }

        // Each reconcile replaces the session's history with exactly the given records.
        let previous = history[session.key] ?? [:]
        history[session.key] = current
        guard policy.notificationsEnabled else { return }

        let deliverableStates = policy.notifyStates[session.key.backend] ?? []
        let candidates = ordered.compactMap { record -> AttentionNotificationEvent? in
            guard deliverableStates.contains(record.state) else { return nil }
            let stamp = RecordStamp(state: record.state, epoch: record.epoch)
            guard previous[Self.key(record)] != stamp else { return nil }
            return AttentionNotificationEvent(
                target: SelectionTarget(target: record.target, sessionDisplayName: session.displayName),
                sessionName: session.displayName,
                visibleLabel: record.visibleLabel,
                status: record.state
            )
        }

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
    }

    func unavailable(session: AgentSessionKey) {
        // Preserve the last authoritative history through the backend's grace period or outage.
    }

    func remove(session: AgentSessionKey) {
        baselinedSessions.remove(session)
        history.removeValue(forKey: session)
    }

    func reset() {
        baselinedSessions.removeAll()
        history.removeAll()
    }

    private static func key(_ record: AttentionRecord) -> RecordKey {
        RecordKey(target: record.target, recordID: record.recordID)
    }
}
```

In `HerdrMenubar/Notifications/NativeNotificationService.swift`, replace

```swift
        content.title = event.status == .blocked ? "Agent blocked" : "Agent finished"
```
with
```swift
        content.title = switch event.status {
        case .blocked: "Agent blocked"
        case .error: "Agent failed"
        case .done: "Agent finished"
        }
```

In `HerdrMenubar/Status/AgentStore.swift` (still pre-backend), make the store feed Herdr records:

- In `.connected`, replace the `reconcile` call with
  ```swift
            await attentionCoordinator.reconcile(
                session: AgentSessionDescriptor(herdr: descriptor),
                records: HerdrBackend.makeSnapshot(snapshot, sessionID: descriptor.id).attention,
                policy: notificationPolicy
            )
  ```
- In `.snapshot(let id, let snapshot)`, replace the `reconcile` call with
  ```swift
            await attentionCoordinator.reconcile(
                session: AgentSessionDescriptor(herdr: state.descriptor),
                records: HerdrBackend.makeSnapshot(snapshot, sessionID: id).attention,
                policy: notificationPolicy
            )
  ```
- Replace `await attentionCoordinator.unavailable(sessionID: id)` with `await attentionCoordinator.unavailable(session: AgentSessionKey(herdr: id))`.
- Replace `await attentionCoordinator.remove(sessionID: id)` with `await attentionCoordinator.remove(session: AgentSessionKey(herdr: id))`.
- Replace `notificationPolicy` with
  ```swift
    var notificationPolicy: NotificationDeliveryPolicy {
        NotificationDeliveryPolicy(
            notificationsEnabled: preferences.notificationsEnabled,
            soundEnabled: preferences.notificationSoundEnabled,
            notifyStates: preferences.notifyStates
        )
    }
  ```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests`
Expected: PASS. `MultiSessionIntegrationTests.testTwoServersDeliverDistinctAttentionTransitionsAndRouteNotificationClickExactly` and `testAcceptedTargetsRouteRepeatedGlobalFocusAcrossTwoServersAndReconnectGrace` prove label-ordered Herdr delivery and the latest-notification target are unchanged end to end.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Notifications HerdrMenubar/Status/AgentStore.swift HerdrMenubarTests
git commit -m "feat: key notification history by record with state and epoch and per-backend states"
```

---

### Task 7: `AgentStore` consumes backends (Herdr cutover, selection steps 0–5)

**Files:**
- Rewrite: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/Menu/StatusMenuPresentation.swift` (`appendAgentSections`, `statusSymbol`)
- Modify: `HerdrMenubar/App/ApplicationRuntime.swift` (`live()`)
- Modify: `HerdrMenubarTests/BackendTestSupport.swift`
- Create: `HerdrMenubarTests/AgentStoreBackendTests.swift`
- Modify tests: `AgentStoreTests`, `StatusMenuPresentationTests`, `MultiSessionIntegrationTests`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: everything from Tasks 1–6; `HerdrBackend(supervisor:terminalActivator:ghosttyFocuser:preferences:)`.
- Produces:
  - `AgentStore.init(backends: [any AgentBackend], attentionCoordinator: any AttentionNotificationCoordinating, notificationService: any NativeNotificationServing, preferences: Preferences = Preferences())`
  - `func start() async`, `func stop() async`, `func retry() async` (calls `retryUnavailable()` on every enabled backend concurrently)
  - `func selectRow(_ target: SelectionTarget) async` (menu row; replaces `select(_ item: AgentMenuItem)`)
  - `func select(_ target: SelectionTarget)` (notification / shortcut / menu action path; unchanged semantics)
  - `attentionSections`, `finishedSections`, `workingSections: [SessionMenuSection]`; `SessionMenuSection { session: AgentSessionDescriptor; items: [AgentRow]; id: AgentSessionKey }`
  - `unavailableSessions: [UnavailableSession]`; `UnavailableSession { session: AgentSessionDescriptor; message; id: AgentSessionKey }`
  - `attentionCount`, `connectionState`, `transientError`
  - Deleted: `AgentMenuItem`, `AgentMenuItemID`, `AgentSelectionTarget`, `AgentStore.sessionOrder(_:_:)` static, store-side Ghostty wording.
  - Test shims: Herdr-only `AgentStore.init(supervisor:terminalActivator:ghosttyFocuser:attentionCoordinator:notificationService:preferences:)`, `AgentStore.select(_ row: AgentRow) async`, `AgentRow.paneID`.
- `.descriptorChanged`, `.backendUnavailable`, `.backendHidden` are accepted and ignored in this task; Task 8 implements them test-first. Herdr never emits them unless `enabledBackends` excludes Herdr.

- [ ] **Step 1: Add store test shims and the new backend-store test file**

Append to `HerdrMenubarTests/BackendTestSupport.swift`:

```swift
extension AgentRow {
    var paneID: String { target.paneID }
}

extension AgentStore {
    /// Herdr-only store with the pre-backend initializer shape, so existing store and
    /// integration tests exercise AgentStore + HerdrBackend unchanged.
    convenience init(
        supervisor: any SessionSupervising,
        terminalActivator: any TerminalActivating,
        ghosttyFocuser: any GhosttySessionFocusing,
        attentionCoordinator: any AttentionNotificationCoordinating,
        notificationService: any NativeNotificationServing,
        preferences: Preferences = Preferences()
    ) {
        self.init(
            backends: [HerdrBackend(
                supervisor: supervisor,
                terminalActivator: terminalActivator,
                ghosttyFocuser: ghosttyFocuser,
                preferences: preferences
            )],
            attentionCoordinator: attentionCoordinator,
            notificationService: notificationService,
            preferences: preferences
        )
    }

    /// Menu-row selection of a Herdr row read from the store's sections.
    func select(_ row: AgentRow) async {
        await selectRow(SelectionTarget(
            target: row.target,
            sessionDisplayName: row.target.session.herdrSessionID?.displayName ?? row.target.session.rawID
        ))
    }
}
```

Create `HerdrMenubarTests/AgentStoreBackendTests.swift`:

```swift
import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class AgentStoreBackendTests: XCTestCase {
    func testCompletedSelectionMarksCapturedSeenTokenBeforeRefresh() async {
        let backend = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow], attention: [])))
        await eventually { store.finishedSections.count == 1 }

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["start", "focus:b1", "activate:b1", "markSeen", "refresh:b1"])
        XCTAssertEqual(backend.markedTokens, [finishedToken])
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testPartialActivationShowsMessageAndMarksNothing() async {
        let backend = FakeAgentBackend(kind: .rex)
        backend.activationResult = "Turn on Remote Control in Rex Settings → Rex Server to switch sessions."
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow], attention: [])))
        await eventually { store.finishedSections.count == 1 }

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["start", "focus:b1", "activate:b1", "refresh:b1"])
        XCTAssertTrue(backend.markedTokens.isEmpty)
        XCTAssertEqual(store.transientError, "Turn on Remote Control in Rex Settings → Rex Server to switch sessions.")
        await store.stop()
    }

    func testFocusFailureShowsBackendWordingWithoutActivationOrRefresh() async {
        let backend = FakeAgentBackend(kind: .rex)
        backend.focusError = .failed("That pane no longer exists in fix-playback")
        let store = makeBackendStore([backend])

        await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(backend.calls, ["focus:b1"])
        XCTAssertEqual(store.transientError, "That pane no longer exists in fix-playback")
    }

    func testSupersededSelectionRefreshesWithoutActivatingOrMarkingSeen() async {
        let backend = FakeAgentBackend(kind: .rex)
        backend.heldFocusPaneIDs = ["b1"]
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow, attentionRow], attention: [])))
        await eventually { store.finishedSections.count == 1 && store.attentionCount == 1 }

        let first = Task {
            await store.selectRow(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))
        }
        await eventually { backend.calls.contains("focus:b1") }
        let second = Task {
            await store.selectRow(SelectionTarget(target: attentionRow.target, sessionDisplayName: "fix-playback"))
        }
        for _ in 0..<20 { await Task.yield() }
        backend.releaseHeldFocus()
        await first.value
        await second.value

        XCTAssertEqual(backend.calls, [
            "start", "focus:b1", "refresh:b1", "focus:b2", "activate:b2", "refresh:b2"
        ])
        XCTAssertTrue(backend.markedTokens.isEmpty)
        XCTAssertNil(store.transientError)
        await store.stop()
    }

    func testFinishedRowsFormTheirOwnSectionAndAreNotCounted() async {
        let backend = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([backend])
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [finishedRow, attentionRow, workingRow], attention: [])))
        await eventually { store.workingSections.count == 1 }

        XCTAssertEqual(store.attentionCount, 1)
        XCTAssertEqual(store.attentionSections.flatMap(\.items), [attentionRow])
        XCTAssertEqual(store.finishedSections.flatMap(\.items), [finishedRow])
        XCTAssertEqual(store.workingSections.flatMap(\.items), [workingRow])
        await store.stop()
    }

    func testSessionsSortByBackendKindThenBackendComparator() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex, herdr])
        await store.start()
        let herdrZulu = AgentSessionDescriptor(key: AgentSessionKey(backend: .herdr, rawID: "named:zulu"), displayName: "zulu")
        let rexBeta = AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s2"), displayName: "beta")
        rex.send(.connected(rexBeta, BackendSnapshot(rows: [row(rexBeta.key, "x", .working)], attention: [])))
        rex.send(.connected(rexSession, BackendSnapshot(rows: [row(rexKey, "y", .working)], attention: [])))
        herdr.send(.connected(herdrZulu, BackendSnapshot(rows: [row(herdrZulu.key, "z", .working)], attention: [])))
        await eventually { store.workingSections.count == 3 }

        XCTAssertEqual(store.workingSections.map(\.session.displayName), ["zulu", "beta", "fix-playback"])
        await store.stop()
    }
}

// MARK: - Fixtures

private let rexKey = AgentSessionKey(backend: .rex, rawID: "s1")
private let rexSession = AgentSessionDescriptor(key: rexKey, displayName: "fix-playback")
private let finishedToken = SeenToken(marks: ["s1/b1/:3"])
private let finishedRow = AgentRow(
    target: AgentTarget(session: rexKey, paneID: "b1"), displayLabel: "Review", agentLabel: "claude-code",
    state: .finished, subtitle: "done · claude-code", seenToken: finishedToken
)
private let attentionRow = AgentRow(
    target: AgentTarget(session: rexKey, paneID: "b2"), displayLabel: "Playback", agentLabel: "pi",
    state: .attention(.blocked), subtitle: "blocked · Allow rm -rf build?", seenToken: nil
)
private let workingRow = AgentRow(
    target: AgentTarget(session: rexKey, paneID: "b3"), displayLabel: "Design", agentLabel: "claude-code",
    state: .working, subtitle: "working · claude-code", seenToken: nil
)

private func row(_ key: AgentSessionKey, _ paneID: String, _ state: RowState) -> AgentRow {
    AgentRow(
        target: AgentTarget(session: key, paneID: paneID), displayLabel: paneID, agentLabel: nil,
        state: state, subtitle: "", seenToken: nil
    )
}

@MainActor
private func makeBackendStore(
    _ backends: [any AgentBackend],
    coordinator: BackendStoreCoordinator = BackendStoreCoordinator(),
    enabledBackends: [String] = ["herdr", "rex"]
) -> AgentStore {
    let defaults = UserDefaults(suiteName: "dev.herdr.menubar.backend-store-tests.\(UUID().uuidString)")!
    defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey)
    return AgentStore(
        backends: backends,
        attentionCoordinator: coordinator,
        notificationService: BackendStoreNotifications(),
        preferences: Preferences(defaults: defaults)
    )
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition())
}

@MainActor
private final class FakeAgentBackend: AgentBackend {
    nonisolated let kind: BackendKind
    private(set) var calls: [String] = []
    private(set) var markedTokens: [SeenToken] = []
    var focusError: FocusError?
    var activationResult: String?
    var heldFocusPaneIDs: Set<String> = []
    private var continuation: AsyncStream<BackendEvent>.Continuation?
    private var focusWaiters: [CheckedContinuation<Void, Never>] = []

    init(kind: BackendKind) { self.kind = kind }

    func events() async -> AsyncStream<BackendEvent> {
        let (stream, continuation) = AsyncStream<BackendEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() async { calls.append("start") }

    func stop() async {
        calls.append("stop")
        continuation?.finish()
        continuation = nil
    }

    func retryUnavailable() async { calls.append("retry") }

    func focusServer(_ target: AgentTarget) async throws {
        calls.append("focus:\(target.paneID)")
        if heldFocusPaneIDs.contains(target.paneID) {
            await withCheckedContinuation { focusWaiters.append($0) }
        }
        if let focusError { throw focusError }
    }

    func activate(_ target: AgentTarget) async -> String? {
        calls.append("activate:\(target.paneID)")
        return activationResult
    }

    func refreshAfterSelection(_ target: AgentTarget) async { calls.append("refresh:\(target.paneID)") }

    func markSeen(_ token: SeenToken) async {
        calls.append("markSeen")
        markedTokens.append(token)
    }

    func clearFinished() async { calls.append("clearFinished") }

    nonisolated func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        lhs.displayName < rhs.displayName
    }

    func send(_ event: BackendEvent) { continuation?.yield(event) }

    func releaseHeldFocus() {
        heldFocusPaneIDs.removeAll()
        let waiters = focusWaiters
        focusWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor BackendStoreCoordinator: AttentionNotificationCoordinating {
    private(set) var reconciledSessions: [AgentSessionKey] = []
    private(set) var unavailableSessions: [AgentSessionKey] = []
    private(set) var removedSessions: [AgentSessionKey] = []

    func reconcile(session: AgentSessionDescriptor, records: [AttentionRecord], policy: NotificationDeliveryPolicy) {
        reconciledSessions.append(session.key)
    }
    func unavailable(session: AgentSessionKey) { unavailableSessions.append(session) }
    func remove(session: AgentSessionKey) { removedSessions.append(session) }
    func reset() {}
}

private actor BackendStoreNotifications: NativeNotificationServing {
    func responses() async -> NotificationResponseSubscription { .finished() }
    func requestAuthorization() async throws -> Bool { true }
    func settings() async -> NotificationSystemSettings { .authorized }
    func deliver(_ event: AttentionNotificationEvent, sound: Bool) async throws -> NotificationDeliveryResult {
        .accepted
    }
}
```

Register `AgentStoreBackendTests.swift` in `HerdrMenubar.xcodeproj/project.pbxproj`:

1. After the `BB0000000000000000000005 /* BackendTestSupport.swift in Sources */ = {isa = PBXBuildFile; …};` line insert
   `		BB0000000000000000000006 /* AgentStoreBackendTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000016 /* AgentStoreBackendTests.swift */; };`
2. After the `BB0000000000000000000015 /* BackendTestSupport.swift */ = {isa = PBXFileReference; …};` line insert
   `		BB0000000000000000000016 /* AgentStoreBackendTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AgentStoreBackendTests.swift; sourceTree = "<group>"; };`
3. In the `HerdrMenubarTests` group, after `				BB0000000000000000000015 /* BackendTestSupport.swift */,` insert `				BB0000000000000000000016 /* AgentStoreBackendTests.swift */,`
4. In the test Sources phase, after `				BB0000000000000000000005 /* BackendTestSupport.swift in Sources */,` insert `				BB0000000000000000000006 /* AgentStoreBackendTests.swift in Sources */,`

- [ ] **Step 2: Migrate the existing store-facing tests**

Run:

```bash
perl -0pi -e 's/store\.select\(AgentMenuItem\(\s*session:\s*([\w.]+),\s*pane:\s*(?:\w+\.)?pane\("([^"]+)",\s*\.\w+\)\s*\)\)/store.selectRow(.herdr($1.id, paneID: "$2"))/g' HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/StatusMenuPresentationTests.swift && perl -pi -e 's/AgentMenuItemID\(sessionID:/AgentTarget(session:/g' HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/MultiSessionIntegrationTests.swift
```

Hand edits in `HerdrMenubarTests/AgentStoreTests.swift`:

- In `testWezTermSelectionUsesGenericActivationOnly`, replace
  ```swift
        let item = AgentMenuItem(session: workDescriptor, pane: pane("p", .blocked))

        await store.select(item)
  ```
  with
  ```swift
        await store.selectRow(.herdr(workDescriptor.id, paneID: "p"))
  ```
- In `testUnavailableClearsOnlyOwningSessionAndKeepsAggregateConnected`, replace
  `UnavailableSession(session: workDescriptor, message: "socket unavailable")`
  with
  `UnavailableSession(session: AgentSessionDescriptor(herdr: workDescriptor), message: "socket unavailable")`.
- Delete the five label tests now covered by `HerdrBackendTests` (Task 4): `testJoinedLabelsMatchHerdrForSingleAndMultiTabWorkspaces`, `testVisibleLabelsIncludeAgentContextWithoutDuplicateSuffixes`, `testSecondaryLabelsPreservePaneAndDisplayAgentPreference`, `testJoinedLabelFallsBackThroughPaneTitleLabelAndID`, `testDistinctSnapshotTabsMakeWorkspaceMultiTabWhenCountIsStale`. Also delete the now-unused private helpers `workspace(_:label:tabCount:)` and `tab(_:workspaceID:label:)` at the bottom of the file.
- Add a store-level `named:default` test:
  ```swift
    func testNamedDefaultSessionStaysDistinctFromDefaultSession() async {
        let supervisor = FakeSessionSupervisor()
        let store = makeStore(supervisor: supervisor)
        await store.start()
        await supervisor.send(.connected(defaultDescriptor, snapshot([pane("p", .done)])))
        await supervisor.send(.connected(descriptor("default"), snapshot([pane("p", .done)])))
        await eventually { store.attentionCount == 2 }

        XCTAssertEqual(store.attentionSections.map(\.id), [.default, .named("default")])
        XCTAssertEqual(store.attentionSections.map(\.session.displayName), ["Default", "default"])
        await store.stop()
    }
  ```

Run: `grep -n "AgentMenuItem" HerdrMenubarTests/*.swift`
Expected: no output.

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/AgentStoreBackendTests`
Expected: FAIL — `extra arguments at positions … in call` / `value of type 'AgentStore' has no member 'selectRow'`.

- [ ] **Step 4: Rewrite `AgentStore`**

Replace `HerdrMenubar/Status/AgentStore.swift` with:

```swift
import Foundation
import Observation
import OSLog

enum ConnectionState: Equatable, Sendable {
    case searching
    case noSessions
    case connecting
    case connected
}

struct SessionMenuSection: Identifiable, Equatable, Sendable {
    let session: AgentSessionDescriptor
    let items: [AgentRow]
    var id: AgentSessionKey { session.key }
}

struct UnavailableSession: Identifiable, Equatable, Sendable {
    let session: AgentSessionDescriptor
    let message: String
    var id: AgentSessionKey { session.key }
}

private struct SessionPresentationState {
    var descriptor: AgentSessionDescriptor
    var isConnected = false
    var unavailableMessage: String?
    private(set) var rows: [AgentRow] = []
    private(set) var attentionRows: [AgentRow] = []
    private(set) var finishedRows: [AgentRow] = []
    private(set) var workingRows: [AgentRow] = []

    init(descriptor: AgentSessionDescriptor) {
        self.descriptor = descriptor
    }

    /// Sections and badge come from `RowState` only.
    mutating func setRows(_ newRows: [AgentRow]) {
        rows = newRows
        attentionRows = newRows.filter(\.isAttention).sorted(by: AgentRow.attentionOrder)
        finishedRows = newRows.filter { $0.state == .finished }.sorted(by: AgentRow.labelOrder)
        workingRows = newRows.filter { $0.state == .working }.sorted(by: AgentRow.labelOrder)
    }
}

private extension AgentRow {
    var isAttention: Bool {
        if case .attention = state { return true }
        return false
    }
}

@Observable @MainActor
final class AgentStore {
    private let backends: [any AgentBackend]
    private let attentionCoordinator: any AttentionNotificationCoordinating
    private let notificationService: any NativeNotificationServing
    private let preferences: Preferences
    private var eventTasks: [Task<Void, Never>] = []
    private var notificationResponseTask: Task<Void, Never>?
    private var notificationResponseSubscription: NotificationResponseSubscription?
    private var pendingNotificationTarget: SelectionTarget?
    private var eventGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var startToken: UUID?
    private var startCallingBackendsToken: UUID?
    private var stopTask: Task<Void, Never>?
    private var stopToken: UUID?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var isRunning = false
    private var discoveredBackends: Set<BackendKind> = []
    private var sessions: [AgentSessionKey: SessionPresentationState] = [:]

    private(set) var connectionState: ConnectionState = .searching
    private(set) var transientError: String?

    var attentionSections: [SessionMenuSection] { sections(\.attentionRows) }
    var finishedSections: [SessionMenuSection] { sections(\.finishedRows) }
    var workingSections: [SessionMenuSection] { sections(\.workingRows) }

    var unavailableSessions: [UnavailableSession] {
        sessions.values.compactMap { state in
            state.unavailableMessage.map { UnavailableSession(session: state.descriptor, message: $0) }
        }
        .sorted { sessionOrder($0.session, $1.session) }
    }

    var attentionCount: Int {
        sessions.values.reduce(into: 0) { $0 += $1.attentionRows.count }
    }

    init(
        backends: [any AgentBackend],
        attentionCoordinator: any AttentionNotificationCoordinating,
        notificationService: any NativeNotificationServing,
        preferences: Preferences = Preferences()
    ) {
        self.backends = backends
        self.attentionCoordinator = attentionCoordinator
        self.notificationService = notificationService
        self.preferences = preferences
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        let generation = UUID()
        eventGeneration = generation
        let token = UUID()
        let precedingStop = stopTask
        startToken = token
        let task = Task { [weak self] in
            await precedingStop?.value
            guard let self, self.ownsStart(generation: generation, token: token) else { return }

            var streams: [(BackendKind, AsyncStream<BackendEvent>)] = []
            for backend in self.backends {
                let events = await backend.events()
                guard self.ownsStart(generation: generation, token: token) else { return }
                streams.append((backend.kind, events))
            }

            let notificationResponses = await self.notificationService.responses()
            guard self.ownsStart(generation: generation, token: token) else {
                notificationResponses.cancel()
                return
            }

            for (kind, events) in streams {
                self.eventTasks.append(Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { return }
                        await self?.consume(event, from: kind, generation: generation)
                    }
                })
            }
            self.notificationResponseSubscription = notificationResponses
            self.notificationResponseTask = Task { [weak self] in
                defer { notificationResponses.cancel() }
                for await target in notificationResponses {
                    guard !Task.isCancelled else { return }
                    self?.select(target)
                }
            }
            self.startCallingBackendsToken = token
            for backend in self.backends {
                await backend.start()
                guard self.ownsStart(generation: generation, token: token) else { return }
            }
            self.startCallingBackendsToken = nil
        }
        startTask = task
        await task.value
        if startToken == token {
            startTask = nil
            startToken = nil
            if startCallingBackendsToken == token {
                startCallingBackendsToken = nil
            }
        }
    }

    func stop() async {
        if !isRunning, let stopTask {
            await stopTask.value
            return
        }
        guard isRunning || startTask != nil || !eventTasks.isEmpty
            || notificationResponseTask != nil || selectionTask != nil else { return }

        isRunning = false
        eventGeneration = UUID()
        selectionGeneration = UUID()
        let selection = selectionTask
        selectionTask = nil
        selection?.cancel()
        let startingBackends = startCallingBackendsToken == startToken ? startTask : nil
        startTask?.cancel()
        startTask = nil
        startToken = nil
        startCallingBackendsToken = nil

        let consumers = eventTasks
        eventTasks = []
        consumers.forEach { $0.cancel() }
        let responseConsumer = notificationResponseTask
        notificationResponseTask = nil
        let responseSubscription = notificationResponseSubscription
        notificationResponseSubscription = nil
        pendingNotificationTarget = nil
        responseSubscription?.cancel()
        responseConsumer?.cancel()
        discoveredBackends.removeAll()
        sessions.removeAll()
        connectionState = .searching
        transientError = nil

        let precedingStop = stopTask
        let token = UUID()
        let backends = self.backends
        let coordinator = attentionCoordinator
        let task = Task {
            await precedingStop?.value
            await selection?.value
            for consumer in consumers { await consumer.value }
            await responseConsumer?.value
            await startingBackends?.value
            await coordinator.reset()
            for backend in backends { await backend.stop() }
        }
        stopToken = token
        stopTask = task
        await task.value
        if stopToken == token {
            stopTask = nil
            stopToken = nil
        }
    }

    func retry() async {
        transientError = nil
        let enabled = preferences.enabledBackends
        let targets = backends.filter { enabled.contains($0.kind) }
        await withTaskGroup(of: Void.self) { group in
            for backend in targets {
                group.addTask { await backend.retryUnavailable() }
            }
        }
    }

    /// A menu row was chosen.
    func selectRow(_ target: SelectionTarget) async {
        pendingNotificationTarget = nil
        await startSelection(target)?.value
    }

    /// A notification click, the latest-notification shortcut, or a menu action.
    func select(_ target: SelectionTarget) {
        guard isRunning else { return }
        receiveNotificationTarget(target, generation: eventGeneration)
    }
}

private extension AgentStore {
    func backend(for kind: BackendKind) -> (any AgentBackend)? {
        backends.first { $0.kind == kind }
    }

    @discardableResult
    func startSelection(_ target: SelectionTarget) -> Task<Void, Never>? {
        guard stopTask == nil else { return nil }
        guard let backend = backend(for: target.target.session.backend) else { return nil }
        // Step 0: capture the token from the store's own row cache for every selection source.
        let seenToken = sessions[target.target.session]?.rows.first { $0.target == target.target }?.seenToken
        let generation = UUID()
        selectionGeneration = generation
        transientError = nil
        let predecessor = selectionTask
        predecessor?.cancel()
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self, self.ownsSelection(generation) else { return }
            await self.performSelection(target, backend: backend, seenToken: seenToken, generation: generation)
            if self.selectionGeneration == generation {
                self.selectionTask = nil
            }
        }
        selectionTask = task
        return task
    }

    func performSelection(
        _ target: SelectionTarget,
        backend: any AgentBackend,
        seenToken: SeenToken?,
        generation: UUID
    ) async {
        // Step 1.
        do {
            try await backend.focusServer(target.target)
        } catch {
            AppLog.systemActions.error("Pane focus failed: \(error.localizedDescription, privacy: .private)")
            if ownsSelection(generation) {
                transientError = error.localizedDescription
            }
            return
        }

        // Step 2.
        guard ownsSelection(generation) else {
            await backend.refreshAfterSelection(target.target)
            return
        }

        // Step 3.
        let partial = await backend.activate(target.target)
        if ownsSelection(generation), let partial {
            transientError = partial
        }

        // Step 4.
        if ownsSelection(generation), partial == nil, let seenToken {
            await backend.markSeen(seenToken)
        }

        // Step 5.
        await backend.refreshAfterSelection(target.target)
    }

    func ownsSelection(_ generation: UUID) -> Bool {
        selectionGeneration == generation && !Task.isCancelled
    }

    func ownsStart(generation: UUID, token: UUID) -> Bool {
        isRunning && eventGeneration == generation && startToken == token && !Task.isCancelled
    }

    func consume(_ event: BackendEvent, from kind: BackendKind, generation: UUID) async {
        guard isRunning, eventGeneration == generation else { return }
        switch event {
        case .discovery(let descriptors):
            discoveredBackends.insert(kind)
            for descriptor in descriptors where sessions[descriptor.key] == nil {
                sessions[descriptor.key] = SessionPresentationState(descriptor: descriptor)
            }
            discardAbsentPendingTarget(kind: kind, discovered: descriptors)
        case .connected(let descriptor, let snapshot):
            var state = sessions[descriptor.key] ?? SessionPresentationState(descriptor: descriptor)
            state.descriptor = descriptor
            state.isConnected = true
            state.unavailableMessage = nil
            state.setRows(snapshot.rows)
            sessions[descriptor.key] = state
            await attentionCoordinator.reconcile(
                session: descriptor,
                records: snapshot.attention,
                policy: notificationPolicy
            )
            if let pendingNotificationTarget,
               pendingNotificationTarget.target.session == descriptor.key {
                receiveNotificationTarget(pendingNotificationTarget, generation: generation)
            }
        case .snapshot(let key, let snapshot):
            guard var state = sessions[key], state.isConnected else { return }
            state.setRows(snapshot.rows)
            sessions[key] = state
            await attentionCoordinator.reconcile(
                session: state.descriptor,
                records: snapshot.attention,
                policy: notificationPolicy
            )
        case .sessionUnavailable(let key, let message):
            guard var state = sessions[key] else { return }
            state.isConnected = false
            state.unavailableMessage = message
            state.setRows([])
            sessions[key] = state
            await attentionCoordinator.unavailable(session: key)
        case .removed(let key):
            let removedState = sessions.removeValue(forKey: key)
            if let pendingNotificationTarget, pendingNotificationTarget.target.session == key {
                self.pendingNotificationTarget = nil
                let name = removedState?.descriptor.displayName ?? pendingNotificationTarget.sessionDisplayName
                transientError = "\(name) is unavailable"
            }
            guard removedState != nil else { return }
            await attentionCoordinator.remove(session: key)
        case .descriptorChanged, .backendUnavailable, .backendHidden:
            break
        }
        deriveConnectionState()
    }

    var notificationPolicy: NotificationDeliveryPolicy {
        NotificationDeliveryPolicy(
            notificationsEnabled: preferences.notificationsEnabled,
            soundEnabled: preferences.notificationSoundEnabled,
            notifyStates: preferences.notifyStates
        )
    }

    func receiveNotificationTarget(_ target: SelectionTarget, generation: UUID) {
        guard isRunning, eventGeneration == generation else { return }
        supersedeSelection()
        let kind = target.target.session.backend
        guard let state = sessions[target.target.session] else {
            if discoveredBackends.contains(kind) {
                pendingNotificationTarget = nil
                transientError = "\(target.sessionDisplayName) is unavailable"
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
        startSelection(SelectionTarget(target: target.target, sessionDisplayName: state.descriptor.displayName))
    }

    func supersedeSelection() {
        selectionGeneration = UUID()
        transientError = nil
        selectionTask?.cancel()
    }

    func discardAbsentPendingTarget(kind: BackendKind, discovered: [AgentSessionDescriptor]) {
        guard let pendingNotificationTarget,
              pendingNotificationTarget.target.session.backend == kind,
              sessions[pendingNotificationTarget.target.session] == nil,
              !discovered.contains(where: { $0.key == pendingNotificationTarget.target.session }) else {
            return
        }
        self.pendingNotificationTarget = nil
        transientError = "\(pendingNotificationTarget.sessionDisplayName) is unavailable"
    }

    func deriveConnectionState() {
        if sessions.values.contains(where: \.isConnected) {
            connectionState = .connected
        } else if discoveredBackends.isEmpty {
            connectionState = .searching
        } else if sessions.isEmpty {
            connectionState = .noSessions
        } else {
            connectionState = .connecting
        }
    }

    func sections(_ keyPath: KeyPath<SessionPresentationState, [AgentRow]>) -> [SessionMenuSection] {
        sessions.values.compactMap { state in
            let rows = state[keyPath: keyPath]
            return rows.isEmpty ? nil : SessionMenuSection(session: state.descriptor, items: rows)
        }
        .sorted { sessionOrder($0.session, $1.session) }
    }

    /// `BackendKind` order, then the owning backend's comparator.
    func sessionOrder(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        if lhs.key.backend != rhs.key.backend {
            return lhs.key.backend.sortIndex < rhs.key.backend.sortIndex
        }
        guard let backend = backend(for: lhs.key.backend) else {
            return lhs.key.rawID < rhs.key.rawID
        }
        return backend.compareSessions(lhs, rhs)
    }
}
```

In `HerdrMenubar/Menu/StatusMenuPresentation.swift`, replace the row mapping inside `appendAgentSections` with:

```swift
            nodes.append(contentsOf: section.items.map { row in
                .agent(
                    title: row.visibleLabel,
                    subtitle: row.subtitle,
                    symbol: statusSymbol(row.state),
                    quieter: quieter,
                    target: SelectionTarget(target: row.target, sessionDisplayName: section.session.displayName)
                )
            })
```

and replace `statusSymbol(_:)` with:

```swift
    func statusSymbol(_ state: RowState) -> String {
        switch state {
        case .attention(.blocked):
            "exclamationmark.triangle.fill"
        case .attention(.error):
            "xmark.octagon"
        case .attention(.done), .finished:
            "checkmark.circle.fill"
        case .working:
            "ellipsis.circle"
        }
    }
```

In `HerdrMenubar/App/ApplicationRuntime.swift` `live()`, replace the `let store = AgentStore(…)` block with:

```swift
        let herdrBackend = HerdrBackend(
            supervisor: supervisor,
            terminalActivator: TerminalActivationService(),
            ghosttyFocuser: ghosttyFocuser,
            preferences: preferences
        )
        let store = AgentStore(
            backends: [herdrBackend],
            attentionCoordinator: attentionCoordinator,
            notificationService: notificationService,
            preferences: preferences
        )
```

Run: `grep -rn "AgentMenuItem\|AgentSelectionTarget" HerdrMenubar HerdrMenubarTests`
Expected: no output.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests`
Expected: PASS. Every `AgentStoreTests` case now runs through `HerdrBackend` (via the test-only initializer), so this is the step-1 behaviour gate for supersession, exact-session focus without fallback, Ghostty partial messages, pending-target grace hold, session order, Ghostty forget on removal, retry, and stop ordering. If a positive assertion that used a fixed number of `Task.yield()`s flakes because events now take one extra hop through `HerdrBackend`, convert it to the existing `eventually`/`waitUntil` helpers; do not change production timing.

- [ ] **Step 6: Commit**

```bash
git add HerdrMenubar/Status/AgentStore.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubar/App/ApplicationRuntime.swift HerdrMenubarTests HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "refactor: drive AgentStore from agent backends with HerdrBackend"
```

---

### Task 8: Store handling of descriptor, backend-outage and hidden events; disabled targets; aggregation; wording

**Files:**
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/Menu/StatusMenuPresentation.swift` (`make`)
- Test: `HerdrMenubarTests/AgentStoreBackendTests.swift`

**Interfaces:**
- Consumes: Task 7 store; `Preferences.enabledBackends`; `AgentWording`.
- Produces on `AgentStore`:
  - `private(set) var activeBackends: Set<BackendKind>` — a backend is active once it emitted `.discovery` in this run.
  - `private(set) var unavailableBackends: [BackendKind: String]` — set by `.backendUnavailable(reason)`, cleared by that backend's next `.discovery` or `.backendHidden`. (Rendering the RECONNECTING "Rex" line is step 2.)
  - `var wording: AgentWording` — `.agents` when Rex is active, else `.herdr`.
  - `.descriptorChanged` updates the display name only (no coordinator call).
  - `.backendUnavailable`: clears that backend's rows, marks its sessions not connected, calls `coordinator.unavailable(session:)`; those sessions are excluded from `unavailableSessions` and `connectionState`.
  - `.backendHidden`: removes that backend's sessions and their coordinator history, forgets activity, discards its pending target with "<Kind> is not available".
  - Targets: backend missing from `enabledBackends` → "<Kind> is turned off"; enabled but no backend instance → "<Kind> is not available".
  - `connectionState` per the spec's aggregation table (per-backend state first, so Herdr-only is exactly today's).
  - `StatusMenuPresentationBuilder.make` passes `store.wording`.

- [ ] **Step 1: Write the failing tests**

Append inside `AgentStoreBackendTests`:

```swift
    func testBackendUnavailableClearsRowsKeepsHistoryAndHidesSessionsFromReconnecting() async {
        let backend = FakeAgentBackend(kind: .rex)
        let coordinator = BackendStoreCoordinator()
        let store = makeBackendStore([backend], coordinator: coordinator)
        await store.start()
        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [attentionRow], attention: [])))
        await eventually { store.attentionCount == 1 }

        backend.send(.backendUnavailable("watcher exited"))
        await eventually { store.attentionCount == 0 }

        XCTAssertEqual(store.unavailableBackends, [.rex: "watcher exited"])
        XCTAssertTrue(store.unavailableSessions.isEmpty)
        // `waitUntil` is the shared helper in HerdrClientTestSupport.swift.
        await waitUntil { await coordinator.unavailableSessions == [rexKey] }
        let unavailable = await coordinator.unavailableSessions
        let removed = await coordinator.removedSessions
        XCTAssertEqual(unavailable, [rexKey])
        XCTAssertTrue(removed.isEmpty)

        backend.send(.discovery([rexSession]))
        await eventually { store.unavailableBackends.isEmpty }
        await store.stop()
    }

    func testBackendHiddenRemovesSessionsAndHistory() async {
        let backend = FakeAgentBackend(kind: .rex)
        let coordinator = BackendStoreCoordinator()
        let store = makeBackendStore([backend], coordinator: coordinator)
        await store.start()
        backend.send(.discovery([rexSession]))
        backend.send(.connected(rexSession, BackendSnapshot(rows: [attentionRow], attention: [])))
        await eventually { store.attentionCount == 1 }

        backend.send(.backendHidden)
        await eventually { store.attentionSections.isEmpty }
        await waitUntil { await coordinator.removedSessions == [rexKey] }

        let removed = await coordinator.removedSessions
        XCTAssertEqual(removed, [rexKey])
        XCTAssertFalse(store.activeBackends.contains(.rex))
        XCTAssertEqual(store.wording, .herdr)
        await store.stop()
    }

    func testDescriptorChangedRenamesHeadingWithoutTouchingCoordinator() async {
        let backend = FakeAgentBackend(kind: .rex)
        let coordinator = BackendStoreCoordinator()
        let store = makeBackendStore([backend], coordinator: coordinator)
        await store.start()
        backend.send(.connected(rexSession, BackendSnapshot(rows: [attentionRow], attention: [])))
        await eventually { store.attentionCount == 1 }

        backend.send(.descriptorChanged(AgentSessionDescriptor(key: rexKey, displayName: "renamed")))
        await eventually { store.attentionSections.first?.session.displayName == "renamed" }

        let reconciled = await coordinator.reconciledSessions
        XCTAssertEqual(reconciled, [rexKey])
        await store.stop()
    }

    func testTargetForDisabledBackendIsDiscardedAsTurnedOff() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr], enabledBackends: ["herdr"])
        await store.start()

        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(store.transientError, "Rex is turned off")
        XCTAssertEqual(herdr.calls, ["start"])
        await store.stop()
    }

    func testTargetForEnabledBackendWithoutInstanceIsNotAvailable() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let store = makeBackendStore([herdr], enabledBackends: ["herdr", "rex"])
        await store.start()

        store.select(SelectionTarget(target: finishedRow.target, sessionDisplayName: "fix-playback"))

        XCTAssertEqual(store.transientError, "Rex is not available")
        await store.stop()
    }

    func testWordingSwitchesToAgentsOnlyOnceRexIsActive() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([herdr, rex])
        await store.start()
        herdr.send(.discovery([]))
        await eventually { store.connectionState == .noSessions }
        XCTAssertEqual(store.wording, .herdr)

        rex.send(.discovery([]))
        await eventually { store.wording == .agents }
        XCTAssertEqual(store.activeBackends, [.herdr, .rex])
        await store.stop()
    }

    func testConnectionStateAggregatesActiveBackendsWithHerdrPrecedence() async {
        let herdr = FakeAgentBackend(kind: .herdr)
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([herdr, rex])
        await store.start()

        rex.send(.discovery([]))
        await eventually { store.activeBackends.contains(.rex) }
        XCTAssertEqual(store.connectionState, .searching)

        herdr.send(.discovery([]))
        await eventually { store.connectionState == .noSessions }

        rex.send(.discovery([rexSession]))
        await eventually { store.connectionState == .connecting }

        rex.send(.connected(rexSession, .empty))
        await eventually { store.connectionState == .connected }

        rex.send(.backendUnavailable("heartbeat timeout"))
        await eventually { store.connectionState == .noSessions }
        await store.stop()
    }

    func testRexOnlyActiveWithZeroSessionsIsNoSessions() async {
        let rex = FakeAgentBackend(kind: .rex)
        let store = makeBackendStore([rex], enabledBackends: ["rex"])
        await store.start()
        XCTAssertEqual(store.connectionState, .searching)

        rex.send(.discovery([]))
        await eventually { store.connectionState == .noSessions }
        await store.stop()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/AgentStoreBackendTests`
Expected: FAIL — `value of type 'AgentStore' has no member 'unavailableBackends'`.

- [ ] **Step 3: Implement**

In `HerdrMenubar/Status/AgentStore.swift`:

Add after `private(set) var transientError: String?`:

```swift
    /// Backends that have emitted `.discovery` in this run.
    private(set) var activeBackends: Set<BackendKind> = []
    /// Whole-backend outages; their sessions are excluded from RECONNECTING and connection state.
    private(set) var unavailableBackends: [BackendKind: String] = [:]

    var wording: AgentWording { activeBackends.contains(.rex) ? .agents : .herdr }
```

Replace `unavailableSessions` with:

```swift
    var unavailableSessions: [UnavailableSession] {
        sessions.values.compactMap { state in
            guard unavailableBackends[state.descriptor.key.backend] == nil else { return nil }
            return state.unavailableMessage.map { UnavailableSession(session: state.descriptor, message: $0) }
        }
        .sorted { sessionOrder($0.session, $1.session) }
    }
```

In `stop()`, after `discoveredBackends.removeAll()` add:

```swift
        activeBackends.removeAll()
        unavailableBackends.removeAll()
```

In `consume(_:from:generation:)`, replace the `.discovery` case body with:

```swift
        case .discovery(let descriptors):
            discoveredBackends.insert(kind)
            activeBackends.insert(kind)
            unavailableBackends[kind] = nil
            for descriptor in descriptors where sessions[descriptor.key] == nil {
                sessions[descriptor.key] = SessionPresentationState(descriptor: descriptor)
            }
            discardAbsentPendingTarget(kind: kind, discovered: descriptors)
```

and replace `case .descriptorChanged, .backendUnavailable, .backendHidden: break` with:

```swift
        case .descriptorChanged(let descriptor):
            guard var state = sessions[descriptor.key] else { break }
            state.descriptor = descriptor
            sessions[descriptor.key] = state
        case .backendUnavailable(let reason):
            unavailableBackends[kind] = reason
            AppLog.systemActions.error(
                "\(kind.displayName, privacy: .public) unavailable: \(reason, privacy: .private)"
            )
            let keys = sessions.keys.filter { $0.backend == kind }
            for key in keys {
                sessions[key]?.isConnected = false
                sessions[key]?.setRows([])
            }
            for key in keys {
                await attentionCoordinator.unavailable(session: key)
            }
        case .backendHidden:
            unavailableBackends[kind] = nil
            activeBackends.remove(kind)
            discoveredBackends.remove(kind)
            let keys = sessions.keys.filter { $0.backend == kind }
            for key in keys {
                sessions.removeValue(forKey: key)
            }
            if let pendingNotificationTarget, pendingNotificationTarget.target.session.backend == kind {
                self.pendingNotificationTarget = nil
                transientError = "\(kind.displayName) is not available"
            }
            for key in keys {
                await attentionCoordinator.remove(session: key)
            }
```

Replace `receiveNotificationTarget(_:generation:)` with:

```swift
    func receiveNotificationTarget(_ target: SelectionTarget, generation: UUID) {
        guard isRunning, eventGeneration == generation else { return }
        supersedeSelection()
        let kind = target.target.session.backend
        guard preferences.enabledBackends.contains(kind) else {
            pendingNotificationTarget = nil
            transientError = "\(kind.displayName) is turned off"
            return
        }
        guard backend(for: kind) != nil else {
            pendingNotificationTarget = nil
            transientError = "\(kind.displayName) is not available"
            return
        }
        guard let state = sessions[target.target.session] else {
            if discoveredBackends.contains(kind) {
                pendingNotificationTarget = nil
                transientError = "\(target.sessionDisplayName) is unavailable"
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
        startSelection(SelectionTarget(target: target.target, sessionDisplayName: state.descriptor.displayName))
    }
```

Replace `deriveConnectionState()` with:

```swift
    /// Per-backend state (Herdr's is exactly the pre-backend derivation), then the spec's
    /// aggregation: any connected, any connecting, Herdr's own state, Rex active with zero
    /// sessions, otherwise searching.
    func deriveConnectionState() {
        let enabled = preferences.enabledBackends
        var states: [BackendKind: ConnectionState] = [:]
        for backend in backends where enabled.contains(backend.kind) && unavailableBackends[backend.kind] == nil {
            let kind = backend.kind
            guard kind == .herdr || activeBackends.contains(kind) else { continue }
            let kindSessions = sessions.values.filter { $0.descriptor.key.backend == kind }
            if kindSessions.contains(where: \.isConnected) {
                states[kind] = .connected
            } else if !discoveredBackends.contains(kind) {
                states[kind] = .searching
            } else if kindSessions.isEmpty {
                states[kind] = .noSessions
            } else {
                states[kind] = .connecting
            }
        }
        if states.values.contains(.connected) {
            connectionState = .connected
        } else if states.values.contains(.connecting) {
            connectionState = .connecting
        } else if let herdrState = states[.herdr] {
            connectionState = herdrState
        } else if states[.rex] == .noSessions {
            connectionState = .noSessions
        } else {
            connectionState = .searching
        }
    }
```

In `HerdrMenubar/Menu/StatusMenuPresentation.swift` `make(…)`, replace `let wording = AgentWording.herdr` with `let wording = store.wording`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests`
Expected: PASS. `AgentStoreTests.testEmptyDiscoveryAndConnectingStatesAreDistinct`, `testGraceEntryRemainsUntilRemovedEvent`, `testStopCancelsConsumerAndRejectsLateEvents` and the `StatusMenuPresentationTests` connection-copy tests prove Herdr-only connection states and strings are unchanged.

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/Status/AgentStore.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubarTests/AgentStoreBackendTests.swift
git commit -m "feat: handle backend outage, hidden and descriptor events in AgentStore"
```

---

### Task 9: Step-1 gate verification

**Files:** none modified (verification only; fix forward in the owning task's files if anything fails).

**Interfaces:**
- Consumes: the complete step-1 tree.
- Produces: evidence that the spec's "Step 1 gate" passes and nothing user-visible changed.

- [ ] **Step 1: Confirm removed names are gone**

Run: `grep -rn "NotificationSelectionTarget\|AgentMenuItem\|AgentSelectionTarget\|sessionOrder(_ lhs: SessionDescriptor" HerdrMenubar HerdrMenubarTests`
Expected: no output.

- [ ] **Step 2: Run the full hermetic suite**

Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Map the gate to tests**

Confirm each spec gate item has a passing test:

| Spec "Step 1 gate" item | Tests |
|---|---|
| Supersession (current activates; superseded cannot, still refreshes) | `AgentStoreTests.testSupersededSuccessfulSelectionCannotActivateAndStillRefreshes`, `testSupersededFailedSelectionCannotActivateOrPublishError`, `testRapidSecondSelectionCancelsAndAwaitsFirstFinalization`, `AgentStoreBackendTests.testSupersededSelectionRefreshesWithoutActivatingOrMarkingSeen` |
| Exact-session focus, no fallback; Ghostty partial messages | `AgentStoreTests.testGhosttySelectionFocusesExactSessionWithoutGenericActivation`, `testRemovedSessionAbandonsDirectTargetWithoutFallback`, `testDirectTargetAfterAuthoritativeAbsencePublishesUnavailableWithoutFallback`, `testNoAttachedSurfaceShowsPartialErrorAndStillRefreshesOwningSession`, `testGhosttyControlFailuresAreActionableAndStillRefreshOnce`, `testHerdrFocusFailureSkipsAdapterActivationAndRefresh`, `HerdrBackendTests.testFocusServerWrapsFailureWithSessionNameWording`, `testGhosttyActivationFocusesExactSessionAndReportsPartialFocus` |
| Pending-target grace hold | `AgentStoreTests.testDirectTargetSurvivesGraceOmissionsAndRunsExactlyOnceOnReconnect`, `testNotificationTargetSurvivesRepeatedEmptyDiscoveryDuringUnavailableGrace`, `testNotificationTargetWaitsAcrossUnavailableAndSelectsOnReconnect` |
| Notification baseline, transitions, label-ordered delivery, latest target | `AttentionNotificationCoordinatorTests` (all pane-list tests), `HerdrBackendTests.testAttentionRecordsAreLabelOrderedDeduplicatedLastWinsAndHerdrShaped`, `MultiSessionIntegrationTests.testTwoServersDeliverDistinctAttentionTransitionsAndRouteNotificationClickExactly`, `testAcceptedTargetsRouteRepeatedGlobalFocusAcrossTwoServersAndReconnectGrace` |
| Session order, Ghostty forget on removal, retry | `AgentStoreTests.testSortsDefaultBeforeNamedSessionsAndRowsWithinSession`, `testCaseFoldEquivalentSessionNamesUseStableSessionIDTieBreaker`, `testUnavailablePreservesCoordinatorHistoryAndRemovedForgetsExactlyOnce`, `testRemovedSessionForgetsPendingGhosttyCleanup`, `testRetryDelegatesToUnavailableSessions`, `HerdrBackendTests.testRemovalForgetsGhosttyStateOnlyForForwardedSessionsAndOnlyOnce`, `testCompareSessionsKeepsTodaysComparator` |
| `named:default` vs default | `AgentBackendTypesTests.testHerdrSessionKeysEncodeDefaultAndNamedDefaultDistinctly`, `HerdrBackendTests.testNamedDefaultAndDefaultProduceDistinctTargets`, `AgentStoreTests.testNamedDefaultSessionStaysDistinctFromDefaultSession`, `NativeNotificationServiceTests.testDefaultNamedAndNamedDefaultPayloadsRoundTripAsVersionTwo` |
| Payload v1 round trip | `NativeNotificationServiceTests.testVersionOnePayloadDecodesThroughHerdrPath`, `testPayloadVersionAcceptsOnlyIntegerOneAndTwo` |
| No user-visible change | `StatusMenuPresentationTests` (full menu snapshots and copy), `MenuBarIconTests`, `StatusItemControllerTests`, `SketchyBarIntegrationTests` unchanged and passing |

- [ ] **Step 4: Build and analyze the app**

Run: `xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **` with no new warnings in the touched files.

Run: `xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'`
Expected: `** ANALYZE SUCCEEDED **`.

- [ ] **Step 5: Manual no-change check (with operator approval only)**

With Herdr running and the built app launched: the menu, badge, tooltip, notification titles/bodies, clicking a new notification, and the latest-notification shortcut behave exactly as before. Clicking a notification delivered by a pre-step-1 build (payload v1) still focuses its pane. Do not change live preferences.

- [ ] **Step 6: Commit (only if Step 1–4 required fixes)**

```bash
git add HerdrMenubar HerdrMenubarTests HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "test: close step-1 backend layer gate"
```

---

## Self-review notes

- **Spec coverage (step 1):** types and protocol (Task 1); preference keys/defaults (Task 2); wording input (Task 3); `HerdrBackend` with focus/activate/refresh split, Ghostty forget guard, row/attention construction moved from `AgentMenuItem`, label-ordered attention, one-to-one events, disabled → `.backendHidden` (Task 4); `SelectionTarget` migration across every listed file and payload v2 encode with v1+v2 decode (Task 5); coordinator `(AgentTarget, recordID)` → `(state, epoch)`, per-reconcile replacement, `notifyStates`, given-order delivery, `Agent failed` title (Task 6); store keyed by `AgentSessionKey`, `RowState` sections incl. `.finished`, selection steps 0–5 with the `ownsSelection` gate (Task 7); outage/hidden/descriptor events, disabled-backend targets, aggregation, wording (Task 8); gate (Task 9).
- **Deliberately not in step 1** (see outlines): Rex pending-target deadline and conditions (a)–(d) beyond "turned off"/"not available"; RECONNECTING backend line, FINISHED section, Clear Finished, `Backend · ` heading prefix; `NotificationSettingsController.notifyStates(for:)`/`setNotifyState`; `StatusMenuNode.submenu` state; `.clearFinished`/`.setNotifyState` actions.
- **Type consistency checked:** `selectRow(_:)`/`select(_:)`, `HerdrBackend.makeSnapshot(_:sessionID:)`, `HerdrBackend.row(for:sessionID:workspace:tab:workspaceIsMultiTab:)`, `reconcile(session:records:policy:)`, `unavailable(session:)`, `remove(session:)`, `Preferences.setNotifyStates(_:for:)`, `Preferences.enabledBackendsKey`, `AgentWording.sessionsNoun` are used identically in every task.

---

## Outline: Step 2 — Rex backend, complete, off by default (no code yet)

1. **`JSONLineFramer` opt-in `maxLineLength`** — Herdr unchanged; overflow is a framing error.
2. **`ManagedProcess`** — argv-only `Process`, environment minus `REX_*`, stdout through the framer (4 MiB for the watcher), 16 KiB stderr ring, `terminate()` (SIGTERM, 1 s, SIGKILL) on cancel/stop/failure, generation-tagged lines, one-shot timeouts (version 2 s, server status 3 s, focus 5 s), process-group kill for the shell probe.
3. **Rex CLI resolution** — `rexCLIPath`, versioned candidates then Homebrew/local paths, shell probe gated on Rex.app and once per launch, `rex version` parsing (API ≥ 10), `server status --json` version matching (exit 1 = unreachable), next-candidate on failure, `.backendHidden` (never found, 5-minute recheck) vs `.backendUnavailable` (previously found). Add `rexCLIPath` preference read.
4. **Bundled `RexWatcher.lua`** — resource registration, recorded fixtures from the live server, watcher integration test (skipped without a valid CLI).
5. **Line decoding** — lenient arrays (`{}` = `[]`), RFC 3339 → integer microseconds, typed line enum incl. errors.
6. **Pure reducer** — per-generation reset, backend-level last-known records with epochs from one counter, `via` check, re-read replacement, drop/prune, held blocks, `block_closed`, `session_destroyed`, `session_created`, `snapshot_done` emissions (`.discovery`, `.connected`, `.removed`), descriptor changes, error handling before/after snapshot.
7. **Rows and ranking** — `blocked > working > error > done`, ties by epoch, default window/block label detection, agent label, subtitle, sanitization (Cf/control removal, whitespace collapse, 200 chars).
8. **Seen-state** — `(record key, epoch)` marks, `seenToken` per row, `markSeen`, `clearFinished`, pruning, fresh `.snapshot` after either.
9. **Flap protection** — settling with an injected clock (1.5 s), first-snapshot baseline, settled-by-epoch across generations, timers cancelled on stop.
10. **`RexBackend` actor lifecycle** — `start()` returns promptly, 20 s snapshot deadline, 15 s heartbeat supervision from `snapshot_done`, backoff 1/2/5/15/60 s (exit 4 → 60 s), `retryUnavailable` semantics, per-session coalescing, stop resets known sessions.
11. **Focus** — client selection rule, `focusServer` exit-code table (`not_found`, 3, 4, other), `activate` outcomes (no client, Remote Control off, disconnected), cancellation before activating Rex.app.
12. **Store: Rex pending-target rules** — store-owned deadline with injected clock (30 s), conditions (a)–(d) and their messages, cancellation on supersede/resolve/discard/stop.
13. **Presentation** — FINISHED section + **Clear Finished** (`StatusMenuAction.clearFinished`, runtime dependency, `store.clearFinished()` → backend), `Backend · ` group-heading prefix with more than one active backend, RECONNECTING **Rex** line from `unavailableBackends` (reason in tooltip), "No active agents" over three sections, Retry shown for backend lines.
14. **Rex notifications** — `AttentionNotificationEvent.message`, Rex body (`msg` first line, `<primary label> — Rex · <session label>`), titles already in place.
15. **Wiring and verification** — build `RexBackend` in `ApplicationRuntime.live` when enabled, badge/SketchyBar counts (Rex `done` excluded), cross-backend supersession test (Rex child terminated, Rex.app not activated), Herdr-only visibility tests (Rex absent/disabled/stopped produce today's model and strings), manual live check with Remote Control on.

## Outline: Step 3 — Settings and default-on (no code yet)

1. **`StatusMenuNode.submenu` gains `state`** — checkmark/dash/none; `StatusItemController` and `DetachedMenuController` render it.
2. **`NotificationSettingsController.notifyStates(for:)` and `setNotifyState(_:enabled:for:)`** over `Preferences.setNotifyStates`.
3. **`StatusMenuAction.setNotifyState(BackendKind, AttentionState, Bool)`** — runtime dependency and `ApplicationRuntime.perform` handling.
4. **Menu** — "Herdr Agents" (Blocked, Finished) when Herdr is enabled; "Rex Agents" (Blocked, Failed, Finished) only when Rex is enabled and resolved a CLI this run, or `notifyStates.rex` is stored (needs a store-visible "Rex resolved" signal from `RexBackend`). Accept NSMenu closing on toggle.
5. **Default-on** — `Preferences.defaultEnabledBackends` becomes `[.herdr, .rex]`; tests for absent-key behaviour; README note listing the Herdr notification-states submenu as the intentional visible change.
