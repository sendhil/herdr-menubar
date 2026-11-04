# Ghostty Session Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Delegate only with explicit operator authorization; otherwise execute inline using the available planning, TDD, and debugging skills.

**Goal:** Make Ghostty the default terminal and focus the exact existing Ghostty surface hosting a selected Herdr session, without requiring WezTerm.

**Architecture:** Keep Herdr socket monitoring, session-qualified selection, notifications, and shortcuts unchanged. Replace the WezTerm-specific terminal backend with Ghostty's native macOS scripting/Apple Event API, retaining the existing temporary-title marker and cancellation-safe cleanup algorithm. Retain application-level activation for the other recognized terminals rather than build a multi-backend framework.

**Tech Stack:** Swift 6, AppKit, Foundation, Carbon/Apple Events, XCTest, Xcode 26, macOS 26, Ghostty 1.4.0, Herdr public socket API.

## Global Constraints

- **Execution update (user: “keep going”):** Implement with hermetic tests first and defer Task 1 live focus/Automation verification until the app is ready. No live probe launch or running-app changes during implementation. Passing mocks/builds is not evidence that live Ghostty session focus works; report the deferred smoke tests explicitly.
- Target Ghostty **1.4.0 or newer** initially, matching the installed version and inspected scripting dictionary. AppleScript was introduced in 1.3.0, but 1.3 compatibility is not promised by this plan.
- Preserve the current macOS 26.0 deployment target, Swift 6.0 setting, and KeyboardShortcuts 3.0.1 dependency.
- Herdr remains the source of truth. Never implement independent acknowledgement or agent-status state.
- Focus the exact `SessionID` and pane supplied by the menu, notification, or latest-notification shortcut. Never substitute another session, tab, or pane.
- Never create a Ghostty window, tab, split, shell, or Herdr attachment to satisfy a focus request. Do not launch Ghostty if it is not already running for session-aware focus.
- Match an opaque temporary marker by exact equality at **terminal-surface** level, not by workspace label, CWD, visible window/tab title, PID heuristics, or tab index.
- Do not modify Ghostty configuration, title overrides, keybindings, themes, shell hooks, or the user's dotfiles.
- No Accessibility, Input Monitoring, System Events UI scripting, simulated keystrokes, shell wrappers, terminal plugins, or background polling helper.
- Ghostty control uses Automation permission; never prompt during startup, session discovery, notification delivery, or background refresh.
- All ordinary tests remain hermetic and must not send Apple Events to the user's running Ghostty or trigger a TCC prompt.
- Preserve private logging of dynamic paths, titles, IDs, and errors.
- Historical WezTerm/SSH design documents remain historical. The SSH/remote-session plan is not implemented by this migration.
- Do not uninstall WezTerm from the Mac, install/relaunch Herdr Menubar, change live preferences, or perform live focus tests without separate operator approval.

---

## Findings from repository inspection

Inspected at HEAD `fa1b01d` on 2026-11-03. The only pre-existing untracked work was `.pi/`.

| Component | Current behavior | Migration consequence |
| --- | --- | --- |
| `System/TerminalActivationService.swift` | Ghostty is already recognized as `com.mitchellh.ghostty`; generic activation uses `NSWorkspace`. | No work is needed to discover Ghostty as an installed application. |
| `System/Preferences.swift` | Fresh installs default to `com.github.wez.wezterm`. | A new default alone does not migrate stored WezTerm preferences. |
| `Status/AgentStore.swift` | Sends `pane.focus`; only invokes a session-aware adapter when the selected bundle ID is WezTerm. | Ghostty currently brings the app forward but can show the wrong tab/window/split. |
| `System/WezTermFocusAdapter.swift` | Sets an opaque Herdr client-title marker, polls exact titles, clears the marker, then activates the selected pane. | Reuse this algorithm, including timeout, cleanup, session-lifecycle, and selection-serialization behavior. |
| `System/WezTermCLI.swift` | Calls `wezterm cli list --format json` and `activate-pane`. | Replace the control mechanism, not these CLI arguments. Ghostty is not a drop-in WezTerm CLI. |
| `App/ApplicationRuntime.swift` | Constructs the runner, WezTerm CLI, adapter, and store using one supervisor. | Wire a Ghostty controller and the same supervisor into the replacement adapter. |
| Notifications and shortcuts | Already route into `AgentStore` with exact session/pane targets. | Do not add separate Ghostty selection paths. |
| `Info.plist` | Does not declare `NSAppleEventsUsageDescription`. | Add the usage description and validate permission attribution from the actual app. |
| `System/BoundedProcessRunner.swift` | Its only production consumer is the WezTerm CLI. | Becomes removable once the native Ghostty backend replaces WezTerm. |

### Installed capability evidence

Read-only inspection found:

- Ghostty **1.4.0**, stable, installed at `/Applications/Ghostty.app`.
- Herdr **0.9.5**.
- Xcode selected at `/Applications/Xcode.app/Contents/Developer`.
- `/Applications/Ghostty.app/Contents/Resources/Ghostty.sdef` exposes application-wide `terminals`; each terminal has a stable text `id` and its current title as `name`.
- The dictionary's `focus` command targets an individual terminal and is documented to bring its window forward.
- Ghostty's default configuration reports `macos-applescript = true`. This is the **default**, not a verification of the running application's effective configuration.

No live Ghostty queries, title mutations, permission requests, focus operations, or tests were executed during planning.

Sources:

- [Ghostty AppleScript documentation](https://ghostty.org/docs/features/applescript).
- [Ghostty 1.3 release notes](https://ghostty.org/docs/install/release-notes/1-3-0) for the introduction of scripting support; do not infer 1.3 parity from current docs.
- Installed 1.4.0 `Ghostty.sdef` is the source of truth for the proposed event codes below.

## Approved product scope

**Replace the specialized WezTerm integration rather than support two exact-focus backends.** Make Ghostty the default. Retain WezTerm, iTerm2, Terminal, Kitty, and Alacritty as generic application-activation alternatives; this matches the current explicit generic-WezTerm routing and later-choice preservation contract, superseding the earlier picker-removal wording. Live compatibility remains unverified until the deferred checks pass. Adding exact focus to those alternatives is out of scope.

Preference policy:

1. Missing preference → Ghostty.
2. Stored WezTerm preference → Ghostty, persisted once through the existing preference key.
3. Stored Ghostty or another terminal preference → preserve it exactly.
4. Ghostty absent → keep Ghostty selected as unavailable and offer installed alternatives; do not silently switch to another app.

This is a recommended policy for implementation approval, not permission to modify the user's current preferences during the spike.

## Intended focus sequence

```text
exact Herdr session + pane
    → Herdr pane.focus
    → verify Ghostty running/version and obtain Automation permission if needed
    → resolve prior pending marker cleanup for this session
    → client.window_title.set("herdr-menubar-focus:<random UUID>")
    → enumerate Ghostty terminals and find exactly one matching terminal.name
    → retain its stable terminal ID and running Ghostty process identity
    → client.window_title.clear
    → recheck selection/session/process validity
    → focus that existing Ghostty terminal by stable ID
    → refresh only the owning Herdr session
```

Ghostty's `focus` command should select the containing tab/split and bring the window forward. Prove that in Task 1. On the Ghostty path, do **not** subsequently call `NSWorkspace.openApplication`: session-aware focus already activates the existing target, while reopening can undermine the no-new-window guarantee. Other terminals retain their existing generic activation path.

The permission prompt is outside the marker lookup's one-second deadline, and no marker is installed while waiting for the user. If permission is denied, Herdr pane focus may already have succeeded; report a partial-focus error, refresh the owning session, and do not activate an arbitrary Ghostty tab.

---

## File and interface map

Paths below are relative to the repository root.

| File | Responsibility |
| --- | --- |
| `HerdrMenubar/System/GhosttyControl.swift` (new) | Typed surface identity, Ghostty error mapping, running-app/version checks, and control protocol. |
| `HerdrMenubar/System/GhosttyAppleEvents.swift` (new) | Native event descriptors, bounded off-main-thread transport, permission request, and typed reply decoding. |
| `HerdrMenubar/System/GhosttyFocusAdapter.swift` (new port) | Existing Herdr marker lookup and cleanup lifecycle using Ghostty control. |
| `HerdrMenubar/System/FocusTiming.swift` (extract) | Existing shared `FocusTiming` / `LiveFocusTiming`; keeps both adapters buildable until retirement. |
| `HerdrMenubar/Status/AgentStore.swift` | Route Ghostty through exact focus; keep other terminals generic; display partial errors. |
| `HerdrMenubar/App/ApplicationRuntime.swift` | One live controller/adapter wired to the existing supervisor. |
| `HerdrMenubar/System/Preferences.swift` | Default and stored WezTerm migration. |
| `HerdrMenubar/System/TerminalActivationService.swift` | Ghostty-first catalog without WezTerm. |
| `HerdrMenubar/Info.plist` | Automation usage description. |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Explicit app/test source registration and retirement of old source references. |
| `HerdrMenubarTests/GhosttyControlTests.swift` (new) | Fake native-event boundary, typed decoding, permissions, process/version, and timeout tests. |
| `HerdrMenubarTests/GhosttyFocusAdapterTests.swift` (new port) | Preserve existing marker, deadline, cleanup, and lifecycle tests. |
| `HerdrMenubarTests/GhosttyAppleEventsTests.swift` (new) | Descriptor/event encoding and malformed reply fixtures without a live terminal. |
| Existing store/runtime/preference/menu/system/integration tests | Replace WezTerm fixtures, verify one exact-focus path and preference migration. |
| `README.md` and `Config/Version.xcconfig` | Document Ghostty requirements, permissions, behavior, and build revision. |

Use these interfaces throughout the implementation:

```swift
import Foundation

struct GhosttyTerminal: Equatable, Sendable {
    let id: String
    let title: String
}

struct GhosttyProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let launchDate: Date
}

struct GhosttyTerminalSnapshot: Equatable, Sendable {
    let process: GhosttyProcessIdentity
    let terminals: [GhosttyTerminal]
}

enum GhosttyControlConstants {
    static let bundleIdentifier = "com.mitchellh.ghostty"
}

enum GhosttyFocusError: Error, Equatable, Sendable {
    case noAttachedClient
    case unsupportedHerdr
    case ghosttyUnavailable
    case unsupportedGhostty
    case automationDenied
    case ghosttyControlFailed
    case lookupTimedOut
    case ambiguousMarker
    case markerCleanupFailed
    case targetGone
}

@MainActor
protocol GhosttyControlling: Sendable {
    // Returns the currently running, supported Ghostty instance, after
    // permission resolution. Only called for an explicit focus action.
    func prepareForFocus() async throws -> GhosttyProcessIdentity
    func listTerminals(
        process: GhosttyProcessIdentity,
        timeout: Duration
    ) async throws -> GhosttyTerminalSnapshot
    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws
}

@MainActor
protocol GhosttySessionFocusing: Sendable {
    func focusAttachedClient(sessionID: SessionID) async throws
    func forget(sessionID: SessionID)
}
```

Production type names: `LiveGhosttyControl`, `LiveGhosttyAppleEventTransport`, `LiveGhosttyFocusAdapter`. Keep `FocusTiming` / `LiveFocusTiming` and the private bounded cleanup operation from the current adapter unchanged unless tests require a correction. Do not introduce a generic terminal-backend registry.

## Task 1: Prove exact Ghostty focus and Automation attribution

**Deliverable:** A bounded live feasibility report. Live checks are deferred under the user's execution update above; passing hermetic tests does not satisfy them. Do not claim live compatibility or install/relaunch the app while they remain unverified.

**Files:**
- Create: `docs/superpowers/specs/2026-11-03-ghostty-focus-feasibility.md`.
- Temporary probe artifacts belong in a dedicated temporary directory, not in production sources.

- [ ] Record baseline versions with `herdr --version && ghostty +version && xcode-select -p && git rev-parse HEAD && git status --short`.
- [ ] Run the baseline hermetic suite: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests`. Record pass/failure counts; do not attribute pre-existing failures to Ghostty.
- [ ] Obtain explicit approval for the live test and TCC prompt. Ask the user to provide an existing Herdr attachment in Ghostty and a reserved non-agent idle pane. Include a distractor Ghostty tab and, if available, a split and second window. Do not create or attach sessions yourself.
- [ ] With approval, inspect terminal IDs/titles using the installed dictionary. This script only queries; avoid logging private titles in the durable report:

```applescript
tell application id "com.mitchellh.ghostty"
    set rows to {}
    repeat with t in terminals
        set end of rows to {id of t as text, name of t as text}
    end repeat
    return rows
end tell
```

- [ ] Using the existing `SessionSupervising.setClientWindowTitle(sessionID:title:)` / `clearClientWindowTitle(sessionID:timeout:)` path in a disposable probe, prove an opaque UUID marker appears as the exact `name` of one Ghostty **terminal**, including when its tab is not selected. Put clearing in a cancellation-independent cleanup path before setting any marker. Do not set markers on active agent panes.
- [ ] Save only the terminal ID in temporary memory, clear the Herdr marker, and focus that stable ID. Verify its tab, split, and window are selected correctly after the marker has been cleared:

```applescript
on run argv
    set terminalID to item 1 of argv
    tell application id "com.mitchellh.ghostty"
        set matches to every terminal whose id is terminalID
        if (count of matches) is not 1 then error "Target unavailable" number -1728
        focus (item 1 of matches)
    end tell
end run
```

Pass IDs as script arguments; never interpolate titles or IDs into executable source. A CLI `osascript` probe demonstrates Ghostty semantics only, **not** production TCC attribution.

- [ ] Repeat from a disposable, ad-hoc-signed app with bundle ID `dev.herdr.menubar` and the intended usage description using **native Apple Events**. Verify Automation lists **Herdr Menubar → Ghostty**, not a shell, terminal, or unrelated helper. Do not reset the user's TCC database.
- [ ] Prove denial, disabled `macos-applescript`, missing target, and Ghostty exit do not create windows or activate a distractor. Coordinate disabled-scripting testing with the user or use an isolated setup; do not rewrite live configuration.
- [ ] Verify title restoration and that normal monitoring remains healthy after the test. Have the user restore their prior focus if desired.
- [ ] Record gates as PASS/FAIL/NOT RUN: marker propagation, stable-ID focus after clearing, tab/split/window selection, no new surfaces, actual-app TCC attribution, negative paths, title restoration. Claiming verified live compatibility requires all applicable gates to pass; implementation may proceed with these checks explicitly deferred.

## Task 2: Implement the native Ghostty control boundary

**Deliverable:** Independently testable control of an existing Ghostty process, with no CLI or UI-scripting dependency.

**Files:** Create the two control files and their test files from the map; modify `Info.plist` and Xcode source registration.

**Consumes:** Installed dictionary and the feasibility report recording deferred live verification.

**Produces:** `LiveGhosttyControl: GhosttyControlling`, using the exact types above.

- [ ] Write failing descriptor/reply fixture tests before native control implementation. Cover text IDs, Unicode/newlines/tabs in titles, empty lists, malformed entries, duplicate IDs, missing IDs, and oversized replies. Titles must never be split using line/tab delimiters.
- [ ] Add failing controller tests: app absent; app installed but not running; version below 1.4.0; missing `launchDate`; permission allowed/denied/prompt-needed; scripting disabled; process replacement; target closed; lookup timeout; canceled action queued behind another action. No test may send a live Apple Event.
- [ ] Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/GhosttyControlTests -only-testing:HerdrMenubarTests/GhosttyAppleEventsTests`. Expect new behavior assertions to fail before implementation, then pass afterward.
- [ ] Add the exact usage description:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Herdr Menubar controls Ghostty to focus the existing terminal containing the Herdr session you select.</string>
```

- [ ] Resolve an already-running app through `NSRunningApplication.runningApplications(withBundleIdentifier:)`; require one valid supported process identity. Send to that **PID**, not a launchable bundle-ID target. Revalidate PID + launch date before listing and before focus.
- [ ] Implement a fakeable native event transport on one isolated serial executor. Create/use native descriptors on that executor; transfer only Sendable typed values back to the main actor. Do not run synchronous `AESendMessage` or permission prompting on the main actor, and do not move `NSAppleScript` to a worker thread as a shortcut.
- [ ] Encode events using the installed dictionary and Apple Event object-specifier constants:

| Operation | Encoding |
| --- | --- |
| Target | `typeKernelProcessID`, selected running Ghostty PID. |
| Get terminals | `core/getd`, direct parameter: all application `Gtrm` elements. |
| Get properties | `core/getd`, `prop` specifier for `ID  ` or `pnam` on an individual terminal specifier. |
| Terminal by ID | Object specifier class `Gtrm`, `formUniqueID`, text ID, application container. |
| Focus terminal | `Ghst/Fcus`, direct parameter: terminal-by-ID specifier. |
| Reply error | Decode `keyErrorNumber`/`keyErrorString`; never surface raw private error strings. |

Enumeration must retain stable IDs and associate each title with the same terminal object. Do not zip separate positional ID/title lists that can change between events. Reject duplicate IDs and malformed replies. Cap decoded terminal count at 4096 and total decoded ID/title bytes at 256 KiB; treat excess as `ghosttyControlFailed`.

- [ ] Use `AEDeterminePermissionToAutomateTarget` for the exact Ghostty events before installing a marker. First query without prompting; if consent is needed, request it only from the explicit focus action. Map `errAEEventNotPermitted` to `automationDenied`. Permission resolution is outside operational deadlines; queue cancellation must prevent a stale selection from continuing after the user answers.
- [ ] Bound the **entire** listing operation to its caller budget, at most 500 ms, recomputing remaining time between native events. Bound focus to one second. Use finite `AESendMessage` reply timeouts, with native tick rounding accounted for. Check cancellation before dispatch and after each reply. Do not merely time out an awaiting Swift task and leave an unbounded native operation running.
- [ ] Document the native-send limitation: an event already dispatched cannot be reliably recalled. Preserve predecessor draining so a newer selection cannot overtake an outstanding focus send; no canceled queued operation may send afterward. Do not claim cancellation can undo an already-completed OS focus.
- [ ] Preserve the repository's existing ad-hoc signing and non-hardened build policy. Do not enable Hardened Runtime as part of this feature. If an effective hardened build is discovered during the spike, add and validate `com.apple.security.automation.apple-events` for that build rather than silently changing signing policy.
- [ ] Run both new test classes to green; commit the tested control boundary and usage description together.

## Task 3: Port the marker algorithm without losing its safeguards

**Deliverable:** Ghostty session focus with the existing Herdr marker/cleanup invariants.

**Files:** Create `HerdrMenubar/System/GhosttyFocusAdapter.swift` by porting the existing adapter and create `HerdrMenubarTests/GhosttyFocusAdapterTests.swift` by porting its tests. Extract the existing `FocusTiming` / `LiveFocusTiming` definitions verbatim into `HerdrMenubar/System/FocusTiming.swift`, removing just those definitions from `WezTermFocusAdapter.swift`. Register new paths in Xcode. Keep the original WezTerm adapter/tests buildable until Task 5; production routing remains unchanged until Task 4.

**Consumes:** `GhosttyControlling` from Task 2 and the existing `SessionSupervising` interface.

**Produces:** `LiveGhosttyFocusAdapter: GhosttySessionFocusing`.

- [ ] Port the existing tests into the new Ghostty test class mechanically, retaining every current assertion: success order; delayed propagation; duplicate markers; near-match rejection; late results; no foreground client; unsupported Herdr; cancellation-independent cleanup; three cleanup attempts/500 ms; pending cleanup before a new marker; lifecycle invalidation; session removal; per-session isolation; opaque marker privacy. Keep the old test class intact until retirement. Copy the adapter's private bounded-cleanup helper into the new file; extract only the non-private timing definitions to avoid duplicate global types.
- [ ] Change the success oracle to `prepare → set:work:<marker> → list → clear:work → focus:<terminal UUID>`. Add failing assertions that a denied permission installs no marker and never lists/focuses a surface.
- [ ] Add failing assertions for process replacement between lookup and focus, closed target after clearing, non-selected tab/split fixtures, and cancellation after `prepareForFocus` but before marker installation. None may focus a substitute terminal.
- [ ] Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/GhosttyFocusAdapterTests` and confirm new assertions fail before the port is complete.
- [ ] Apply these exact semantic replacements to the existing adapter body:

| Existing | Replacement |
| --- | --- |
| `WezTermSessionFocusing` | `GhosttySessionFocusing` |
| `LiveWezTermFocusAdapter` | `LiveGhosttyFocusAdapter` |
| `WezTermFocusError` | `GhosttyFocusError` |
| `cli: any WezTermCLIControlling` | `control: any GhosttyControlling` |
| `WezTermPane` | `GhosttyTerminal` |
| `listPanes(timeout:)` | `listTerminals(process:timeout:)`, consume `.terminals` only after snapshot process validation |
| `activatePane(id: pane.paneID)` | `focusTerminal(id: terminal.id, process: process)` |
| CLI error conversion | Preserve typed `GhosttyFocusError`; propagate cancellation; map other failures to `ghosttyControlFailed` |

Call `prepareForFocus()` before marker installation, recheck cancellation/session lifecycle after it, and pass its process identity through every lookup/focus call. Keep the one-second overall marker lookup, 50 ms poll interval, exact equality, clear-before-focus order, and existing cleanup retry/pending state. Never clear a user's Ghostty title override to make a marker discoverable: report lookup failure instead.

- [ ] Run all converted tests to green. Commit the adapter and preserved regression suite together.

## Task 4: Route all selection entry points through Ghostty

**Deliverable:** Menu click, notification click, and latest-notification shortcut focus the same exact Ghostty target.

**Files:** Modify `AgentStore.swift`, `ApplicationRuntime.swift`, `AgentStoreTests.swift`, `ApplicationRuntimeTests.swift`, `StatusMenuPresentationTests.swift`, `MultiSessionIntegrationTests.swift`, and any existing test fake referring to the renamed protocol.

**Consumes:** `GhosttySessionFocusing` and live controller/adapter from Tasks 2–3.

**Produces:** An integrated Ghostty path; other terminals retain generic activation.

- [ ] Change the existing `testNonWezTermSelectionSkipsAdapterAndPreservesGenericActivation` test: Ghostty must now use the adapter, while `com.apple.Terminal` is the generic test case. Replace the store's WezTerm success oracle with `focus:work:p → ghostty:work → refresh:work`; generic activation remains `focus → activate:<bundle ID> → refresh`.
- [ ] Preserve all existing overlapping-selection, notification buffering, reconnect-grace, stop/drain, stale-result, and session-removal assertions while converting their fakes to Ghostty.
- [ ] Add failing assertions that Ghostty success **and failure** never call the generic activator, permission requests occur only inside explicit selection, and each partial failure refreshes only the selected session once.
- [ ] Run the four modified test classes before wiring and observe failures in Ghostty routing assertions.
- [ ] Replace the store dependency/property/initializer label `wezTermFocuser` with `ghosttyFocuser`. Route on `GhosttyControlConstants.bundleIdentifier`; call `forget(sessionID:)` on session removal. Keep the serialized `selectionTask`/predecessor draining path unchanged.
- [ ] Before enabling saved-preference migration, ensure hosted XCTest bootstrap uses isolated test-only defaults rather than the real app's `UserDefaults.standard`. Add a hermetic runtime-factory test with a private stand-in app domain; its saved preferences must be untouched in test mode. Suppressing synchronization alone does not prevent an eager `Preferences` initializer from writing a migration.
- [ ] In `ApplicationRuntime.live`, replace runner/CLI/WezTerm construction with one `LiveGhosttyAppleEventTransport`, one `LiveGhosttyControl`, and one `LiveGhosttyFocusAdapter` sharing the existing supervisor. Startup/observation must not send Apple Events.
- [ ] Use this exact partial-focus error copy, prefixed with `Focused the pane in <session>, but `:

| Error | Suffix |
| --- | --- |
| `noAttachedClient`, `lookupTimedOut` | `no attached Ghostty terminal was found.` |
| `unsupportedHerdr` | `this Herdr session must be updated for Ghostty terminal focus.` |
| `ghosttyUnavailable` | `Ghostty is not running or is unavailable.` |
| `unsupportedGhostty` | `Ghostty 1.4.0 or newer is required for terminal focus.` |
| `automationDenied` | `allow Herdr Menubar to control Ghostty in System Settings → Privacy & Security → Automation.` |
| `markerCleanupFailed` | `the temporary Ghostty focus marker could not be cleared.` |
| `targetGone` | `the attached Ghostty terminal is no longer available.` |
| `ambiguousMarker`, `ghosttyControlFailed`, unclassified error | `Ghostty could not be controlled. Check that macos-applescript is enabled.` |

Cancellation continues to be handled by selection ownership; it must not replace a newer selection's message.

- [ ] Run the focused store/runtime/menu/multi-session tests to green, then the full hermetic suite. Commit integrated behavior and all updated fakes together.

## Task 5: Make Ghostty the default and retire WezTerm-only code

**Deliverable:** No WezTerm dependency remains in the running app; fresh and existing WezTerm selections migrate predictably.

**Files:** Modify preferences/catalog and their tests, menu/status fixtures, Xcode project, README, and version config. Delete `HerdrMenubar/System/WezTermCLI.swift`, `HerdrMenubar/System/WezTermFocusAdapter.swift`, `HerdrMenubarTests/WezTermCLITests.swift`, `HerdrMenubarTests/WezTermFocusAdapterTests.swift`, and `HerdrMenubarTests/WezTermSubprocessIntegrationTests.swift`. Delete `HerdrMenubar/System/BoundedProcessRunner.swift` and `HerdrMenubarTests/BoundedProcessRunnerTests.swift` if a final reference check confirms no remaining consumers. Keep the extracted `FocusTiming.swift`.

- [ ] Add failing tests for empty defaults, stored WezTerm migration and persistence, preservation of every other stored bundle ID, second-launch stability, and missing Ghostty remaining selected/unavailable. Assert unrelated notification/login/shortcut preferences are untouched.
- [ ] Implement preference initialization using the existing key; keep a literal legacy ID only for migration:

```swift
static let defaultTerminalBundleIdentifier = "com.mitchellh.ghostty"

// In init(defaults:), after self.defaults = defaults:
let storedTerminal = defaults.string(forKey: Self.selectedTerminalKey)
if storedTerminal == "com.github.wez.wezterm" {
    selectedTerminalBundleIdentifier = Self.defaultTerminalBundleIdentifier
    defaults.set(Self.defaultTerminalBundleIdentifier, forKey: Self.selectedTerminalKey)
} else {
    selectedTerminalBundleIdentifier = storedTerminal ?? Self.defaultTerminalBundleIdentifier
}
```

The explicit `defaults.set` is intentional: property observers do not perform initialization-time persistence.

- [ ] Remove WezTerm from `TerminalCatalog.knownTerminals`; keep Ghostty first, followed by iTerm2, Terminal, Kitty, and Alacritty. Update exact-order tests and unavailable-terminal menu expectations.
- [ ] Run: `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests/PreferencesTests -only-testing:HerdrMenubarTests/SystemServiceTests -only-testing:HerdrMenubarTests/StatusMenuPresentationTests -only-testing:HerdrMenubarTests/StatusItemControllerTests` and get all assertions green.
- [ ] Reference audit: `rg -n 'WezTerm|wezTerm|wezterm|BoundedProcess' HerdrMenubar HerdrMenubarTests HerdrMenubar.xcodeproj README.md`. Expected production WezTerm mentions after cleanup: only the literal migration ID. Historical documents may still mention WezTerm.
- [ ] Remove the unused runner and CLI source/test/project references together. The former subprocess integration tests are not blindly renamed: Tasks 2–4 now test the native event path instead.
- [ ] Update README Features, Status behavior, Notifications, Requirements, Terminal activation, and limitations. State Ghostty ≥1.4.0 + Automation + enabled scripting + existing attachment; other terminal choices are app-level only; no new surfaces; saved WezTerm selection migration; no Accessibility permission or shell config changes.
- [ ] Change `CURRENT_PROJECT_VERSION = 6` to `CURRENT_PROJECT_VERSION = 7` in `Config/Version.xcconfig` (if another distributed build has landed meanwhile, use the next integer after its value). Run the full hermetic suite before committing retirement/default migration and docs.

## Task 6: Validate the built app, installation, and failure behavior

**Deliverable:** Verified ordinary-app Ghostty workflow, not just mocked control tests.

- [ ] Run full unit tests, build, and static analysis as separate commands:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
```

- [ ] Run installer regressions with `bash scripts/tests/install_test.sh`; inspect effective signing/build settings and the built plist's Automation description. Probe changed Swift paths using active LSP diagnostics where available; missing LSP coverage is not proof of a clean build.
- [ ] Request approval before installation/relaunch. With approval, use `./scripts/install.sh --no-launch`, then let the user launch the installed app. Do not rely solely on TCC behavior observed in Xcode/XCTest or a disposable probe.
- [ ] On the actual installed ad-hoc build, verify Herdr Menubar → Ghostty Automation grant, denial/recovery, and permission behavior after a second install. Record any identity-related reauthorization behavior rather than promising permission survives ad-hoc rebuilds.
- [ ] Exercise one default and one named Herdr session across different Ghostty tabs/windows, plus a Ghostty split containing an attachment. Select via menu, notification click, and latest-notification shortcut. Assert exact Herdr pane + exact containing Ghostty surface, no extra surfaces, and cleared titles.
- [ ] Exercise closed attachment, closed target during selection, Ghostty quit/restart, multiple rapid selections, Herdr reconnect, unsupported version, disabled scripting, and denied Automation. No arbitrary-tab fallback; healthy sessions keep monitoring; errors do not overwrite a newer selection.
- [ ] Confirm selecting Terminal/iTerm2 still uses generic app activation, and startup never triggers an Automation prompt.
- [ ] Run `git diff --check` and a final reference audit. Update the feasibility report with installed-app validation and mark the plan steps only on verified success.

## Release acceptance criteria

- Ghostty works with WezTerm absent from the machine.
- Menu/notification/shortcut selection reaches the exact existing Ghostty tab, split, and window hosting the target Herdr session.
- Fresh defaults and saved WezTerm selections choose Ghostty; other preferences remain unchanged.
- No title marker remains after successful focus or recoverable failure; cleanup failures are explicit and block a new marker for that same session until resolved.
- No background permission prompts, Accessibility requirements, shell/dotfile changes, or replacement terminal surfaces.
- Ordinary tests do not interact with live terminal windows; full unit suite, build, analysis, installer regressions, and the approved installed-app smoke checks pass.

## Risk and fallback decisions

1. **Title propagation:** The dictionary exposes terminal titles, but actual propagation from the Herdr thin client must pass Task 1. If an override masks titles, fail clearly; do not mutate the override.
2. **Permission attribution/signing:** The app must own the Automation grant. Native events are preferred over a production `osascript` subprocess specifically to avoid building the design around shell/helper attribution.
3. **Version drift:** Ghostty's scripting API is newer than its basic app activation. Keep the backend narrow and its event codes fixture-tested; use the installed version's dictionary rather than assuming all versions share current online documentation.
4. **Queued focus/cancellation:** Native sends are bounded, not magically recallable. Drain predecessors, invalidate stale session/process identities, and never send a new focus after queued cancellation.
5. **Deferred gate or gate failure:** Keep release compatibility explicitly unverified and stop any live rollout until the operator decides how to proceed. The approved code migration may continue with hermetic tests. Do not substitute CWD guesses, title substring matching, or UI scripting just to claim parity.

## Suggested execution order

Approved implementation-first scope → native control + hermetic fixtures → port cleanup algorithm → integrate shared selection path → migrate default/remove dead WezTerm code → operator-approved deferred live and installed-app validation.

## Current verification checkpoint

- Build 7 implements native exact-session Ghostty focus, safe hosted defaults/one-time migration, Automation declarations, and backend retirement. Generic alternatives remain supported; no Ghostty fallback/terminal creation.
- Hermetic installer: 32 cases GREEN. Post-retirement migration regression checkpoint: 176 tests GREEN. Reconnect repair checkpoint: 42 tests GREEN; `b5dfc2ad5` then passed 150 executions (50 each of the original integration and both deterministic positive/negative regressions).
- `b0b8a5946` ran 436 non-UI tests without skipping the baseline; the only failures are the same three rendered shortcut-accessibility assertions at L173/176/185. Reconnect/native migration cases passed. Diagnostic task #9 is resolved; unrelated task #8 still blocks a full-green release claim.
- Release build `bf06653f2` passed. Read-only strict/deep signature, universal arm64/x86_64 ad-hoc identity, Automation entitlement/purpose, build 7, and deployment 26.0 checks passed. Xcode additionally injected get-task-allow under the existing base-entitlement/ad-hoc settings; no signing mode changes. The build log included automatic Launch Services registration for the DerivedData artifact; no install/launch or registration reversal. Analysis-only `b3e9aa9ef` succeeded with no source diagnostics or new Launch Services step, and the Release signature/Automation entitlement/purpose/build 7 were reverified afterward. Its incremental log contains no fresh Swift compile/analyzer pass; success is not complete Swift AST/opengrep coverage. All 19 changed Swift files passed active LSP; broader analyzer coverage remains incomplete.
- New user approval on 2026-11-04 permits installation, launch, commit, and push. Installer `b0232e7aa` completed: installed/launched build 7 at ~/Applications/Herdr Menubar.app. Strict/deep signature, embedded Automation entitlement/purpose/version, and a running process at that exact installed executable path were verified. This does not verify terminal-focus/title propagation or Automation attribution. Publication destination is master -> origin/master (`https://github.com/sendhil/herdr-menubar.git`), excluding generated .pi artifacts. Normal launch may apply the documented one-time preference migration. No agent-triggered terminal focus/title/Automation permission change or unrelated accessibility repair is approved.

## Execution record

Earlier implementation states below are historical and superseded by later checkpoints and the current verification summary above.

- Baseline: 417 tests ran; three assertions fail in the pre-existing `KeyboardShortcutSettingsTests.testRenderedErrorAccessibilitySpeaksActionAndExactDynamicReason`. Its isolated rerun also fails. Unrelated shortcut behavior is not being changed.
- Live probe: prepared but never launched; subsequently deferred by the user. No live permission/focus/title changes or installation have occurred.
- SourceKit: local pinned build-server metadata plus a refresh of this session's stale helpers fixed Xcode module context; earlier active checks confirmed all three new production files clean. The latest probe after the next slice reports zero findings but is inconclusive for all three files (push-only/silent-on-clean), so Xcode compilation/tests remain the authoritative check. AST scan coverage is also deferred, not a clean verdict.
- First TDD slices: missing-running-app guard, stable-ID/Unicode decoding, allowed preparation, and clear-before-exact-focus reached GREEN after the intended RED assertions. `bc385abf4` passed all 26 selected tests: four Ghostty tests plus the original 22 WezTerm adapter regressions. A genuine Foundation fixture selector compile error was corrected before counting RED.
- Next vertical slices: unsupported-version rejection before permission, already-allowed permission checks for both native events, and 50 ms delayed-title propagation reached the intended assertion RED (`b44a03048`); all four prior Ghostty tests remained green. `b9ec109e8` passed all 29 selected tests (seven Ghostty plus 22 original adapter regressions). None changes production routing or contacts live Ghostty.
- Failure-path slices: malformed version metadata, denied Automation mapping without a prompt, and duplicate-marker failure cleanup reached the intended assertion RED (`b2074452b`); all seven earlier Ghostty tests passed. `b272bed96` passed all 32 selected tests (ten Ghostty plus 22 original adapter regressions). Cleanup retry/deadline/cancellation/lifecycle behavior is not complete yet.
- Identity/deadline slices: process replacement while authorization is suspended, consent-needed permission flow, and one-second near-match rejection with decreasing per-list budgets reached the intended assertion RED (`b659a8e21`). `b813dbe3d` passed all 35 selected tests (13 Ghostty plus 22 original adapter regressions). Permission callbacks are faked; no actual prompt is requested.
- Listing/focus slices: process-qualified controller listing, native focus encoding of an opaque stable ID, and rejection/cleanup of a late exact-marker result reached the intended assertion RED (`b20296ccb`). `baf83e6ed` passed all 38 selected tests (16 Ghostty plus 22 original adapter regressions). Native OS sends remain substituted at the test boundary.
- Attachment/identity slices: controller focus forwarding, rejection of duplicate stable IDs in native replies, and no-attached-client behavior reached the intended assertion RED (`b0d850d03`). `bac3722fe` passed all 41 selected tests (19 Ghostty plus 22 original adapter regressions).
- Stale-target/compatibility slices: process replacement after preparation but before focus, empty stable-ID rejection, and unsupported Herdr method mapping reached the intended assertion RED (`b85545e06`), with all prior 19 Ghostty tests passing. `be4937fc2` passed all 44 selected tests (22 Ghostty plus 22 original adapter regressions).
- Cleanup retry slice: the first ported cleanup regression now checks three bounded attempts with 500/400/300 ms RPC budgets, 100 ms backoffs, a typed cleanup failure, and no focus. `b128fb8a9` reached the intended assertion RED (raw error, duplicate unbounded five-second clear calls, no backoff). `b75e005bb` passed all 45 selected tests (23 Ghostty plus 22 original adapter regressions). A suspended clear is not yet bounded independently, and cancellation/pending-state/lifecycle protections remain for subsequent slices.
- Cleanup deadline slice: a new regression requires completion before a suspended RPC returns, cancellation of the timed-out clear, and rejection of late success. `baafe2787` reached the intended assertion RED: the focus operation waited for the RPC and focused terminal 62 on late success. `b47867599` passed all 46 selected tests (24 Ghostty plus 22 original adapter regressions), including the isolated first-completion-wins deadline race. A test-class length blocker was addressed by moving this test into a same-file extension without changing its behavior. The edit analyzer reports incomplete AST coverage, not a clean verdict.
- Cancellation slice: a new regression requires cancellation during marker lookup to prevent focus while cleanup RPCs and 100 ms retry backoff run independently. `b199e3783` reached the intended assertion RED: cancellation still focused terminal 42 and skipped retry backoff. `b9f5b860c` passed all 47 selected tests (25 Ghostty plus 22 original adapter regressions), covering post-lookup/pre-focus cancellation checks and an independent cleanup task. A fresh active LSP probe of the adapter and its tests reports both clean, with zero diagnostics and no inconclusive coverage; this is not a workspace-wide or live-compatibility verdict.
- Pending-marker slice: a new regression requires a failed cleanup to be retried successfully before setting another marker for the same session. `b69c28980` reached the intended assertion RED: the retry skipped the required initial clear. `b75d59fe3` passed all 48 selected tests (26 Ghostty plus 22 original adapter regressions), verifying failed cleanup is tracked per session and resolved before preparation/title updates. Session removal and in-flight lifecycle invalidation remain.
- Session removal slice: a new regression requires `forget(sessionID:)` to drop pending cleanup so a recreated session does not inherit stale state. `b86360a3b` reached the intended assertion RED (one extra stale clear after `forget`). `b2eab32be` passed all 49 selected tests (27 Ghostty plus 22 original adapter regressions), verifying pending-state removal. A symbol read failed to parse Swift, so the edited method was inspected using a direct file read instead; no parser success is claimed.
- Suspended-set lifecycle slice: a new regression covers session removal while title setting is suspended, with both missing-method and transport-failure replies; the stale operation must cancel and a recreated session must start clean. `bd3f04bbe` reached the intended assertion RED for both late-error variants, with all 12 prior adapter tests passing. `bb67cd214` passed all 50 selected tests (28 Ghostty plus 22 original adapter regressions), verifying lifecycle tokens and stale title-setting error checks. Successful late replies, suspended cleanup, and remaining lifecycle boundaries still require guards and tests.
- Suspended-cleanup lifecycle slice: a new regression covers session removal while clearing is suspended, with both late success and late failure. The old operation must cancel, never focus, and leave a recreated session clean; `b2b81db36` reached the intended assertion RED: both late replies focused terminal 63, and a late failure triggered an extra clear. Cleanup now carries the lifecycle token and checks it before attempts, after RPC/backoff suspension, before pending-state changes, and before focus. `bced1a332` passed all 51 selected tests (29 Ghostty plus 22 original adapter regressions). AST coverage is incomplete; the fresh LSP probe has zero diagnostics but two inconclusive files, not a clean verdict.
- Successful-title lifecycle slice: a new regression covers a marked-client reply and a no-foreground-client reply received after session removal; neither may trigger terminal listing, and both must cancel the stale operation. `b15d24161` reached the intended assertion RED, with all 14 prior adapter tests passing. A lifecycle check immediately after successful title-setting is written, before foreground-client branching or listing; `b87008b6e` passed all 52 selected tests (30 Ghostty plus 22 original adapter regressions).
- Preparation invalidation slice: a new regression suspends preparation at the fake controller boundary, then either cancels the operation or forgets the session. No Herdr title set/clear or terminal focus may follow the preparation reply. `b754c7e2e` reached the intended assertion RED for both invalidation cases: title setting still occurred, and cancellation also cleared a newly installed marker. Immediate post-preparation cancellation/lifecycle checks are written; `b4d75f5e8` passed all 53 selected tests (31 Ghostty plus 22 original adapter regressions).
- Listing identity slice: a new controller regression replaces the process either before listing or while the transport reply is suspended; no snapshot may be labeled with the old identity. `b7fab883e` reached the intended assertion RED for both replacement timings; the already-replaced process also reached the transport. Pre/post-list PID plus launch-date checks are written; `b3bd332c6` passed all 54 selected tests (32 Ghostty plus 22 original adapter regressions). Foundation's native Apple Event header was reviewed in full for the upcoming OS sender; it confirms `stringValue` coerces non-text values, requiring explicit descriptor-type validation.
- Reply typing slice: a new native-descriptor regression substitutes integer descriptors for each terminal's ID and title in turn; neither may be silently coerced into text. `b77bcdf16` reached the intended assertion RED: integer ID and title descriptors were both accepted through string coercion, with all seven prior Apple Event tests passing. Explicit text-type decoding is written; `b56a7573d` passed all 55 selected tests (33 Ghostty plus 22 original adapter regressions). The edit reports incomplete AST coverage, not a clean verdict.
- Native system-sender slice: an inert sender interface and a new full-event/reply regression are written. The OS send closure is substituted and permission remains a refusing stub; no live event is sent. SourceKit cannot resolve the new type in the test import despite its declaration being present. `b5c935538` succeeded at build-for-testing, proving the new declaration and Foundation fixture spellings compile; SourceKit's missing-type finding disappeared afterward (fresh probe is still inconclusive, not confirmed clean). The cause was stale imported-module context. No code/import workaround was needed. The stale cached finding was explicitly marked false-positive using the successful compiler result; live definition navigation from test line 12 now resolves both the sender type and initializer in `GhosttyAppleEvents.swift` (lines 14 and 21). `b720781a2` reached the intended assertion RED using test-without-building: the inert sender returned `ghosttyControlFailed` and never called the substituted OS boundary; all eight prior Apple Event tests passed. Native full-event encoding, wait-for-reply/never-interact options, timeout conversion, and direct-reply extraction are written; `baa98a2cb` passed all 56 selected tests (34 Ghostty plus 22 original adapter regressions). Real OS callbacks, permission forwarding, reply errors/validation, and production wiring remain unfinished.
- Native permission-forwarding slice: an inert injected permission-check interface and a new OS-boundary forwarding regression are written. Actual permission behavior still refuses with `paramErr`; no live permission function runs. SourceKit reports extra initializer argument `permissionCheck` despite the declared parameter, matching the prior stale imported-module issue; `b6d1975ec` succeeded at build-for-testing. The stale initializer finding was marked false-positive using the successful compiler result, and a fresh active LSP probe confirms the test file clean with zero diagnostics. The two long assertions were wrapped without behavior changes. `bd37b9421` reached the intended assertion RED using test-without-building: both calls returned `paramErr` and the injected checker saw no requests, while all nine earlier Apple Event tests passed. `b8d671544` passed all 57 selected tests (35 Ghostty plus 22 original adapter regressions), verifying raw permission forwarding. The SDK permission API documentation was read: it requires an already-running target and must not be called on the main thread; the transport remains actor-isolated off the main actor. Real OS callbacks are not wired or executed yet.
- Native reply-error slice: a new regression returns nonzero error numbers alongside an apparently valid direct payload. Denial, missing object/process, timeout, unsupported event, and generic errors must fail with typed results rather than success. `b2cba7f8d` reached the intended assertion RED for all six error-reply variants (none threw), with all ten prior Apple Event tests passing. Error-number precedence and typed status mapping are written; `be0b81bb6` passed all 58 selected tests (36 Ghostty plus 22 original adapter regressions). Thrown OS errors, malformed replies, and real callbacks still require implementation/verification.
- Thrown-send-error slice: a new regression injects thrown OSStatus-domain errors instead of reply error records, plus foreign-domain and out-of-range codes; the sender must return typed/safe generic failures without leaking raw exceptions or trapping on conversion. `bd8aefb61` reached the intended assertion RED for all eight thrown-error variants (raw errors escaped instead of typed results), with all 11 prior Apple Event tests passing. OSStatus-domain mapping and checked numeric conversion are written; cancellation and already-typed errors remain preserved. `b947b1a47` passed all 59 selected tests (37 Ghostty plus 22 original adapter regressions).
- Malformed error-number slice: a new regression places Unicode text (`0`, a denial code, and a nonnumeric value) in `keyErrorNumber`; all must fail as malformed instead of coercing into success/statuses. `bb391de5f` reached the intended assertion RED: text zero/nonnumeric values became success, and text denial became a typed denial instead of malformed-data failure; all 12 earlier Apple Event tests passed. Signed-32-bit error descriptor type/size validation is written; `b88a9fd97` passed all 60 selected tests (38 Ghostty plus 22 original adapter regressions).
- Void-focus reply slice: a new regression requires an empty successful reply to be accepted only for native `Ghst/Fcus`, while a get request must still contain a direct value. The installed dictionary confirms focus has no result declaration and brings the existing terminal's window to the front; actual behavior remains live-unverified. `b6a717200` reached the intended assertion RED: the empty successful focus reply was rejected, while get's missing-value rejection and all 13 earlier Apple Event tests passed. Missing direct values are now accepted only for `Ghst/Fcus` with an Apple Event reply, after error validation; `b88fa1ae2` passed all 61 selected tests (39 Ghostty plus 22 original adapter regressions).
- Pre-cancelled native-request slice: a deterministic actor-inherited task is cancelled before authorization/focus starts. It must throw cancellation and leave both permission (including consent) and focus boundaries untouched. `bdd104a71` reached the intended assertion RED: cancelled authorization contacted permission/consent checks, and cancelled focus contacted the fake sender and returned `targetGone` rather than cancellation; all 14 earlier Apple Event tests passed. Cancellation checks at both transport entry points are written; `ba70b4443` passed all 62 selected tests (40 Ghostty plus 22 original adapter regressions). All boundaries are local fakes.
- Mid-permission cancellation slice: fake permission callbacks cancel their own request task during either the initial nonprompting check or consent; authorization must throw cancellation and make no subsequent boundary calls. `bea7f0dce` reached the intended assertion RED in both variants: authorization returned success and continued into consent/next-event checks after cancellation; all 15 earlier Apple Event tests passed. Post-permission cancellation checks are written; `bbd9ba0a0` passed all 63 selected tests (41 Ghostty plus 22 original adapter regressions). No native permission function runs.
- Malformed terminal-reference slice: a real native list contains a text entry instead of an object specifier. It must fail as malformed before any property get; the fake sender now records get counts so early rejection is explicit. `bd01280a2` reached the intended assertion RED: a property get was sent and its fake boundary returned `targetGone`, instead of rejecting the malformed entry after one get; all 16 earlier Apple Event tests passed. Object-specifier type validation is written; `b49c30fd4` passed all 64 selected tests (42 Ghostty plus 22 original adapter regressions). Fresh active LSP probes confirmed both the production and test Apple Event files clean (2/2); this is not workspace/live verification.
- Desired-class reference slice: new fixtures return object specifiers for a window, tab, or application instead of a terminal. These must fail before property gets. Test methods are grouped into same-file sender/transport extensions without changing existing behavior. `bd2d64ced` reached the intended assertion RED for all three classes: each was decoded as a terminal and triggered both property gets; all 17 earlier Apple Event tests passed after regrouping. Typed desired-class validation for `Gtrm` is written; `be6d59e95` passed all 65 selected tests (43 Ghostty plus 22 original adapter regressions).
- Snapshot-reply byte-budget slice: the old backend caps complete output at 256 KiB. New native regressions require a shared 256 KiB budget across reference-list and all ID/title descriptor replies, rejecting oversized IDs/titles and individually acceptable titles whose aggregate exceeds the limit. Get counts identify the exceeding reply. `b59c89619` reached the intended assertion RED: all three oversized snapshots were accepted (and the oversized ID caused extra property gets); all 18 earlier Apple Event tests passed. A shared reply-byte budget in the get helper is written, consuming reference and field descriptor bytes before decoding; `b888b539f` passed all 66 selected tests (44 Ghostty plus 22 original adapter regressions).
- Sender-timeout validation slice: new regression rejects zero, negative, and greater-than-one-second waits before the OS send seam, preserving the one-second maximum used by native focus and sub-500-ms get waits. `b05a40850` reached the intended assertion RED for all three waits: no errors were thrown and every invalid wait reached the send callback; all 19 earlier Apple Event tests passed. A pre-construction `0 < timeout <= 1s` guard is written; `b65db85db` passed all 67 selected tests (45 Ghostty plus 22 original adapter regressions). SDK boundary declarations were re-read without executing any native send or permission call.
- Thin live-boundary wiring: `SystemGhosttyAppleEventSender.live()` now supplies Foundation send and Carbon permission callbacks, and the isolated transport defaults to that factory. Injected test initializers retain refusing permission defaults; all tests still replace the OS seams. This connects already-tested encoding/status handling to the SDK, not a claim of live compatibility. Native execution remains deferred; `bcef165bf` compiled the SDK callbacks and passed all 67 selected regressions with fake boundaries. No native send/permission callback was executed.
- Snapshot process-identity slice: new adapter fixtures return marker matches qualified by a different PID or the same PID with a different launch date. Both must fail with `targetGone`, clear the marker, and never focus. Module outlines were unavailable; direct source/test bodies were read without claiming analyzer coverage. `b14737570` reached the intended assertion RED for both identities: no error was returned and terminal 17 was focused; all 16 earlier Ghostty adapter tests passed. Snapshot/preparation identity equality is now checked before marker matching, using existing failure cleanup; `bbde6421e` passed all 68 selected tests (46 Ghostty plus 22 original adapter regressions). Fresh active LSP probes confirmed both changed adapter files clean (2/2), not workspace/live verification.
- Invalidated-lookup slice: new deterministic fixtures forget the session during either a suspended list reply or the 50 ms backoff. The old operation must cancel without another list or any cleanup/focus mutation. Fake list gates are now explicitly one-shot to avoid re-blocking later polls. `b94a163de` reached the intended assertion RED in both variants: the invalidated operation performed another list (and, after the list gate, another backoff); all 17 earlier Ghostty adapter tests passed. Lookup now carries the session lifecycle token and checks it before every list and after replies; `bf1378a51` passed all 69 selected tests (47 Ghostty plus 22 original adapter regressions).
- Invalidated preparation-error slice: scripted denied/unavailable replies arrive after session forget. They must become cancellation without any marker mutation; a recreated session then focuses normally. Preparation gates/results are one-shot fixtures. `b967338db` reached the intended assertion RED for both preparation errors: obsolete errors escaped instead of cancellation; recreated-session and all 18 prior Ghostty adapter checks passed. Preparation error handling now validates the lifecycle before propagating the original error; `b0e413678` passed all 70 selected tests (48 Ghostty plus 22 original adapter regressions). Comparing the original adapter suite identified six remaining legacy regression cases to port without changing existing behavior.
- Legacy regression conversion: six remaining behavioral cases are now ported (list failure cleanup, focus failure ordering, cleanup failure recording, no-foreground pending cleanup, cross-session isolation, marker privacy), without production behavior changes. The 1000-line test-file blocker was resolved by extracting fake support types into explicitly registered `GhosttyFocusTestSupport.swift`; source edits report clean. `bb014bf10` failed compilation before tests ran: module-visible extracted helper names collided with the old backend's file-private fixtures. This is not assertion RED. Scoped LSP rename previews/applications touched only the two Ghostty test files, giving the five colliding support types Ghostty-prefixed names; the old test file is unchanged. Fresh active LSP confirmed both changed test files clean (2/2); opengrep coverage is deferred/incomplete. `b4e3a88b1` passed all 76 selected tests (54 Ghostty plus 22 original adapter regressions). Task #6 is complete under the implementation/automated-test scope; deferred live verification remains task #5.
- Integration task #7 is in progress: `FocusTiming`/`LiveFocusTiming` were moved unchanged into explicitly registered `System/FocusTiming.swift` so Ghostty no longer depends on declarations in the old backend. A write-first/delete-next transient duplicate diagnostic was investigated via current source reads and fresh active LSP (2/2 clean), with no suppression/workaround. `b02a7bf11` passed all 76 selected tests after the extraction. Hosted XCTest defaults must be isolated before any preference migration is enabled.
- Hosted-defaults isolation slice: a new read-only identity regression requires the default preference factory to avoid `UserDefaults.standard` under XCTest, while normal launches retain it. The factory API currently preserves the old standard-defaults behavior; no migration or standard-defaults writes are enabled. Cached test imports report the new member missing despite its source definition, and definition navigation is empty; this is not assertion RED. `bc4254121` completed build-for-testing successfully; definition navigation then resolved the factory and active LSP confirmed both preference files clean (2/2), proving the missing-member import findings were stale without source workarounds or suppressions. `be51f69a0` reached intended assertion RED: hosted defaults were the standard instance; all seven other preferences tests passed. The factory now uses a private per-process suite under XCTest (and never falls back to standard if suite creation fails); normal launches still use standard. An additional read-only check verifies the actual hosted environment/default factory. `bd50238ca` passed all 85 selected tests, including the actual hosted-process signal and implicit factory isolation. This gate is verified before migration. The next slice changes only preference expectations so far: Ghostty default, once-only saved-WezTerm migration, persistence of alternatives, unrelated settings preservation, and preservation of later explicit WezTerm choices. `beb3dee39` reached intended assertion RED (six assertions across three cases; the other preferences cases passed). Preferences now default to Ghostty and apply the saved-WezTerm mapping once before initialization using `ghosttyDefaultMigrationApplied`; subsequent explicit choices and unrelated settings are untouched. `b4627db2b` passed all 88 selected tests. A fresh subsequent active LSP probe confirmed both preference files clean (2/2); AST/Marksman coverage remains incomplete. All executions use injected suites or the verified private hosted-test defaults; no real saved preferences have been migrated. Current diagnostics: ast-grep deferred, active LSP 1/2 confirmed clean and 1 inconclusive, no reported findings—not complete analyzer coverage.
- Native implementation and full focus-regression conversion are hermetically green, not a live-compatible integrated app yet. Production routing, safe defaults migration, permission declarations, old-backend removal, and integrated build/full-suite/installer verification remain. Live permission/focus behavior is unverified. Production routing is still unchanged, so the app is not ready for installation. Ghostty default/migration are implemented and hermetically verified in the worktree only. Routing slice now converts the existing WezTerm-special and Ghostty-generic assertions into the required inverse contract: Ghostty exact-session focus without generic activation afterward; WezTerm generic activation only. The legacy-named injected focus seam/recorder are intentionally unchanged until implementation, avoiding compiler/API failures as RED evidence. `b6a29acae` reached intended assertion RED (four assertions, two tests). Store dependency/property/constructor labels and the four fixture families are now Ghostty-typed. SourceKit's initializer-parameter rename preview returned no edits, so the replacement was previewed and restricted to the store plus four intended test files using unique targeted contexts; original WezTerm adapter tests remain untouched. Runtime now constructs `LiveGhosttyFocusAdapter` with `LiveGhosttyControl.live()` instead of CLI/process runner. The thin running-app SDK provider retains every matching instance and represents missing identity/version metadata with a rejected empty version; its closure has not executed. Cached test imports still expected the old store signature and suggested reverting labels/force casts; source reads confirmed the new declarations, no workaround/suppression was applied. `b830294fd` failed compilation (not test/assertion evidence): one integration test still supplied `LiveWezTermFocusAdapter` to the Ghostty store; the later `.named` contextual inference error was a cascade. The owning-server/duplicate-pane integration was ported to `LiveGhosttyFocusAdapter` with a fully fake process-qualified `IntegrationGhosttyControl` and opaque string surface IDs, retaining title-set/clear and exact-owning-server checks. The integration preference fixture is Ghostty-selected and the test now requires zero generic activations. No conformance shim/cast/suppression was used. `b58b8834d` completed build-for-testing successfully. Fresh active LSP then confirmed six changed runtime/control/store/fixture files clean (6/6), clearing the stale-signature and actual fixture blockers. The store now selects Ghostty's exact focus branch and makes generic activation an `else if` branch; Ghostty success and failure cannot fall through to app activation. A reported 122-character activation log line in the edited area was formatted without changing behavior. `bcd669e0e` passed all 91 selected tests: both routing cases, duplicate-pane owning-server/opaque-surface integration, and the previous 88 tests. The next three-case test contract requires all ten typed Ghostty errors to yield session-qualified actionable reasons while refreshing once and never activating generically. `b50eb4b3a` failed compilation (not RED): the error helper was Ghostty-typed, but `RecordingWezTermFocuser` still stored/accepted `Result<Void, WezTermFocusError>`. Compiler diagnostics identified that exact mismatch; the fake and its two old explicitly typed scripted failures were converted to GhosttyFocusError. Production formatting is unchanged. `ba73d5774` reached intended assertion RED: all ten message assertions failed, with refresh/no-activation assertions passing. A Ghostty-typed formatter is now implemented for every typed error, including actionable Automation/version reasons and disappeared/ambiguous targets. `be978f4f2` passed all 94 selected tests, adding the three typed-error cases to the prior 91. The four scoped private fixture-class renames were applied after that GREEN checkpoint, touching only their respective intended test files. Store regression fixtures now default to Ghostty and use Ghostty event labels; direct-target/notification/serialization/cancellation expectations preserve qualified session/pane requests and require no generic activation. WezTerm's generic case remains explicit, and generic activation failure coverage explicitly chooses Terminal. A reported 65-line stop/restart test was investigated (Swift enclosing-body parser unavailable, direct body read used) and its setup extracted; the initial six-member tuple was rejected, then replaced with a named private fixture struct without suppressions. Fresh active LSP confirms the store and four test files clean (5/5). `bc7d2c203` ran all 181 selected tests and failed three assertions in two leftover legacy expectations: preference change during Herdr focus still expected generic Ghostty activation/focuser bypass, and the complete base-menu snapshot still expected the WezTerm default. No new production defect or baseline-shortcut failure was involved. Those expectations are now ported; the preference-timing test explicitly starts at Terminal before switching to Ghostty during the fake focus callback, preserving its real timing sensitivity under the new default. `b53b7ca95` passed all 181 selected tests, zero failures. The complete converted store/runtime/presentation/multi-session/default/native/legacy checkpoint is GREEN. Next, three read-only packaging assertions require a Ghostty-specific `NSAppleEventsUsageDescription`, an Apple Events Automation entitlement plist, and that both existing Manual/ad-hoc Debug/Release app signing configurations use it. `bf5e019dc` reached the intended three assertion REDs (missing purpose, nil entitlement, zero signing settings), with successful compilation. Added the packaged Ghostty purpose and a minimal `com.apple.security.automation.apple-events = true` plist; explicitly registered its file reference and configured both existing ad-hoc app signing configurations. All three plists/project pass `plutil -lint`. `b443ed749` passed all 198 selected tests, zero failures. Read-only verification of the compiled Debug hosted-test app confirmed its strict code signature and embedded Apple Events Automation entitlement; its additional XCTest-injected debugging/temporary exception entitlements are not evidence of Release packaging. No Automation request and no sandbox/hardened-runtime mode changes. Read-only cleanup inventory confirms remaining backend symbols are confined to the three obsolete production files and four corresponding test suites, except legitimate generic-WezTerm catalog/activation/migration/menu tests and one legacy cleanup test name. Installer review also found its explicit `CODE_SIGN_ENTITLEMENTS=` override clears the new project declaration; a dedicated hermetic argument assertion now requires the checkout-qualified entitlement path, with its plist copied into the temporary fixture repo. `b144bd510` reached the intended installer RED: 31 existing cases passed, only the new entitlement-path assertion failed against the blank override. Replaced that override with the quoted absolute checkout path; all existing signing/lifecycle behavior remains unchanged. `b9ac4a93c` passed all 32 hermetic installer cases, zero failures; no actual install/relaunch occurred. The remaining cleanup test's semantic name was previewed (one edit, AgentStoreTests only) and renamed to Ghostty without changing behavior; semantic references plus a scoped full Swift token inventory found no surviving backend dependencies. After reviewing backend-only tests, removed the three obsolete production files and four backend suites (46 backend-only cases), and their 28 project entries using six merged edits. Shared timing and all converted native/store regressions remain; `plutil` confirms project syntax. `b98c39ee5` passed all 176 post-retirement tests, zero failures, including the renamed session-cleanup test. The converted native/runtime/store/default/system-service integration is GREEN without the obsolete backend. README and feasibility status now describe the native/generic routes, one-time migration, Automation declarations, no fallback, and explicitly deferred live/baseline gates. Fresh active LSP checks passed all 17 changed Swift files. A session-wide cache query remains inconclusive (201 pending paths, largely generated task artifacts); no workspace-clean verdict. Investigated the install-script include/unused warnings by reading scripts/lib.sh and running include-aware `shellcheck -x` plus Bash syntax on both changed scripts: both passed. The reported executable variable is used in the sourced owned_pids helper; marked only that finding false-positive with evidence, without suppressions/source changes. The include hint is a coverage-context limitation, not a source fix. Incremented Config/Version.xcconfig from build 6 to 7 only after the post-retirement GREEN. Reviewed the final tracked runtime/store/preferences/Info/signing diff; selection ownership/serialization stays unchanged and Ghostty never falls through to generic activation. `git diff --check` passes. `b3f05f95c` ran all 434 non-UI tests and failed five assertions: the same three pre-existing shortcut-accessibility assertions at L173/176/185, plus TWO NEW assertions in testAcceptedTargetsRouteRepeatedGlobalFocusAcrossTwoServersAndReconnectGrace at L379/386 (one-second reconnect focus condition unmet; new named server focused IDs empty instead of [duplicate]). This integration case passed the 176-test checkpoint; it is not classified as baseline or dismissed as flaky. Created diagnostic blocker #9 and paused #7 behind it. `bfa8ba301` repeated the unchanged test 20 times; one run reproduced exactly the two reconnect assertions, while the other 19 passed. Added failure-only test diagnostics for reconnect pane-list requests, unavailable sessions, and transient store error; `b60171fbc` reproduced two failed runs out of 50 (four assertions total). Both failures report requests=2, work still unavailable, and no transient focus error. This locates the issue before native Ghostty focus, not at the Automation/marker boundary. No behavior fix or timeout increase. Reviewed exact target callback, synchronous pending-target recording, connected-event replay, client fixture timing, and fixture server lifecycle. The fixture binds/listens synchronously and stop joins workers before unlinking, so a speculative listener-ready sleep is not justified. Source tracing shows the focus RPC precedes Ghostty control, with Supervisor commandClient requiring present+connected runtime. Source tracing identifies a concrete lost-connection ordering: HerdrClient completes its two-pass bootstrap while discovery still marks the runtime absent; Supervisor.forward drops the connected event; after rediscovery HerdrClient.retryNow is a no-op because its own connected flag is already true. Added a separately registered SessionSupervisorGraceTests fixture using an unfolding event stream: a subsequent next-demand is an acknowledgement of the previous synchronous supervisor event handling, so no scheduling sleep is needed. The deterministic positive test requires a connection established before rediscovery to replay and enable only the exact owning client; the negative test prevents replay after a later absent-state disconnect. `b09800494` reached deterministic assertion RED: the positive case failed its connected replay, exact-client command, and owning descriptor assertions; the disconnect-invalidates-replay negative case passed. Implemented one supervisor-only state fix: retain independently observed connection state and latest snapshot while absent, gate publication/commands on presence, replay the same connected runtime when it reappears, and process disconnects while absent to invalidate replay. HerdrClient/native Ghostty behavior and timeouts are unchanged. Resolved the new optional-initialization style finding without suppression. `bb66dd23b` passed all 42 tests: 2 deterministic regressions, 30 existing supervisor cases, and 10 multi-session integrations. Fresh active LSP checked both changed Swift files with no findings; project plist and diff hygiene pass. `b5dfc2ad5` passed all 150 repeated executions (50 each of the original reconnect integration and both new regressions), zero failures. `b0b8a5946` completed full reassessment: 436 tests, only the same three pre-existing accessibility assertions. All reconnect/native cases passed; #9 is resolved and #7 resumed for non-live Release verification. Release build `bf06653f2` and read-only signature/Automation entitlement/purpose/build 7/deployment 26.0 checks passed. Xcode injected get-task-allow and performed its automatic DerivedData Launch Services registration; signing settings were not changed and the artifact was not installed/launched. Analysis-only `b3e9aa9ef` succeeded; the post-analyze signature/entitlement/purpose/build checks also passed. The incremental action is not a fresh Swift static-analysis run, so broader coverage remains inconclusive. Implementation and non-live evidence are at handoff; #7 remains pending behind the known accessibility baseline #8 rather than marking a failing full suite complete. Live verification remains deferred in #5. No full-green unit-suite, installed-app, or live compatibility claim; Release packaging is verified read-only as above; no commits, installation, relaunch, saved-preference/configuration changes, or native permission/event callbacks. A typo finding on the generated task-ID prefix was verified against the JSON/record and marked false-positive without changing task identity, generated telemetry, or adding suppressions. Earlier fixture-conversion/runtime-wiring notes are superseded by the GREEN checkpoints above; installed-app/live execution remains deferred.
