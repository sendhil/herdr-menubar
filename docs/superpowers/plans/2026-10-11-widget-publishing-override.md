# Widget Publishing Override Implementation Plan

> **For agentic workers:** Execute directly in this session using test-first, task-by-task development. Delegation and commits are not authorized. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persisted Off/Automatic control and install the app with Off selected on this Mac.

**Architecture:** Extend the existing Preferences, native menu, owned runtime actions, and publisher actor. Off cancels publication/configuration tasks while keeping the existing event cache; Automatic retains current presence detection. Reuse publication generations and cancellation guards for late replies and ticks.

**Tech Stack:** Swift, AppKit/Observation, actors, WidgetKit, XCTest, Xcode, existing signed installer.

## Global Constraints

- Approved spec: `docs/superpowers/specs/2026-10-11-widget-publishing-override-design.md`.
- Preserve Automatic as the general default; persist Off only for this Mac.
- Off means no widget timers, configuration polling, activity/file I/O, timeline reloads, or widget-driven requests. Existing cheap event-cache bookkeeping remains.
- Preserve menu monitoring, notifications, Herdr connection/deadline behavior, signing identity, App Group and entitlements.
- Do not alter desktop widgets, shared OS preferences/caches, earlier client edits, or unrelated local settings.
- Report the two reproduced baseline unit failures separately; no unfiltered-green claim.
- No commit, push, delegated workers, new dependencies or new production source files.

## Task 1: Regression tests and API contract

**Files:** existing publisher, preferences, menu presentation, runtime and native menu XCTest files.

**Interfaces produced:** `Preferences.widgetUpdatesEnabled: Bool`, `StatusMenuAction.setWidgetUpdates(Bool)`, `AgentWidgetPublisher.start(updatesEnabled: Bool = true)`, `AgentWidgetPublisher.setUpdatesEnabled(_ enabled: Bool)`, and `ApplicationRuntimeDependencies.setWidgetUpdates: (Bool) async -> Void` with a no-op default for existing fixtures.

- [x] Add a compiling menu regression against the existing API; it must fail because the submenu is missing:

```swift
func testWidgetUpdatesSubmenuStartsInAutomatic() throws {
    let menu = PresentationFixture().presentation().menu
    let children = try XCTUnwrap(menu.compactMap { node -> [StatusMenuNode]? in
        guard case .submenu(title: "Widget Updates", children: let children) = node else { return nil }
        return children
    }.first)
    XCTAssertEqual(children.count, 2)
    guard case .action(title: "Automatic", state: .on, isEnabled: true, action: _) = children[1] else {
        return XCTFail("Automatic must be the default checked choice")
    }
}
```

- [x] Run this exact test with `xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -derivedDataPath .build/WidgetOverrideDerivedData CODE_SIGNING_ALLOWED=NO -only-testing:HerdrMenubarTests/StatusMenuPresentationTests/testWidgetUpdatesSubmenuStartsInAutomatic`. Record the assertion failure.
- [x] Add preference regressions for missing-key default, persisted Off/on restoration and independence of other settings; add checked-menu/action and native-renderer tests.
- [x] Add publisher regressions for startup Off despite ghost kinds, cancelling both running loops, late positive query after Off/Auto, old in-flight tick after manual Off, cached-session re-enable, and cancelled obsolete mode changes. Use existing `PublisherHarness`, `PendingWidgetConfigurations` and fake supervisor.
- [x] Add runtime regressions for exact action payload, cancelling superseded widget actions and cancelling/draining on shutdown. Reuse existing owned action harness and signals.
- [x] Record API-missing compiler failures for the new signatures. Where necessary, add only the declared API shape (ignoring the mode/no-op setter) and run again to observe behavioral assertion failures before implementing the mode.

## Task 2: Minimal implementation

**Files:** `Preferences.swift`, `StatusMenuPresentation.swift`, `ApplicationRuntime.swift`, `AgentWidgetPublisher.swift`.

**Interfaces consumed:** contracts and regressions from Task 1.

- [x] Add the observed preference, preserving Automatic when the key is absent:

```swift
static let widgetUpdatesEnabledKey = "widgetUpdatesEnabled"
var widgetUpdatesEnabled: Bool {
    didSet { defaults.set(widgetUpdatesEnabled, forKey: Self.widgetUpdatesEnabledKey) }
}
// In init, after assigning defaults:
widgetUpdatesEnabled = defaults.object(forKey: Self.widgetUpdatesEnabledKey) == nil
    || defaults.bool(forKey: Self.widgetUpdatesEnabledKey)
```

- [x] Add `.setWidgetUpdates(Bool)` and this native submenu after Launch at Login settings:

```swift
nodes.append(.submenu(title: "Widget Updates", children: [
    .action(title: "Off", state: preferences.widgetUpdatesEnabled ? .off : .on,
            isEnabled: true, action: .setWidgetUpdates(false)),
    .action(title: "Automatic", state: preferences.widgetUpdatesEnabled ? .on : .off,
            isEnabled: true, action: .setWidgetUpdates(true))
]))
```

- [x] Add publisher state `private var updatesEnabled = true`. `start(updatesEnabled:)` sets it before subscribing to existing events. Start configuration monitoring only when enabled. Extract the existing monitor creation into `startConfigurationMonitoring(generation:)` and use it from startup and mode changes.
- [x] Implement the setter as a synchronous actor operation, callable with await, so changing mode never waits for WidgetKit:

```swift
func setUpdatesEnabled(_ enabled: Bool) {
    guard !Task.isCancelled, updatesEnabled != enabled else { return }
    updatesEnabled = enabled
    configurationTask?.cancel(); configurationTask = nil
    stopPublishing()
    if enabled, let generation { startConfigurationMonitoring(generation: generation) }
}
```

- [x] Guard configuration monitoring and both pre/post-query checks with `updatesEnabled`, lifetime generation and cancellation. Guard publication ownership with `updatesEnabled` too. Keep existing event cache and stop/shutdown semantics.
- [x] Inject the runtime setter closure, persisting before the actor call and respecting cancellation:

```swift
setWidgetUpdates: { enabled in
    guard !Task.isCancelled else { return }
    preferences.widgetUpdatesEnabled = enabled
    await widgetPublisher.setUpdatesEnabled(enabled)
},
startStore: {
    await widgetPublisher.start(updatesEnabled: preferences.widgetUpdatesEnabled)
    await store.start()
},
```

- [x] Handle `.setWidgetUpdates` as an owned menu action. Store its UUID, cancel the previous task, and launch the latest operation. Make existing `launchMenuAction` return its optional UUID with `@discardableResult`; clear the widget-action ID only when its matching task completes. Other owned actions retain their behavior.
- [x] Run publisher, preferences, runtime, menu and native-controller suites; every new regression must pass. Use active changed-path LSP diagnostics before the build.

## Task 3: Verification and documentation

- [x] Update the exact complete-base-menu expectation for the intentionally added submenu.
- [x] README: describe Widget Updates → Off/Automatic, persisted setting and Off guarantees, retained event cache, stale WidgetKit limitation and independent explicit probe. Remove the unconditional claim that physical removal always stops publishing in a minute.
- [x] Repeat publisher and runtime cancellation regressions with `xcodebuild test-without-building` and `-test-iterations 20`, bounded to these suites.
- [x] Run the broader unit suite excluding only the two previously reproduced baseline failures; verify `git diff --check` and active changed-path LSP coverage.
- [x] Self-review the new delta for generation/cancellation races, late writes, preference scope, source startup ordering and re-enable behavior. Compare earlier client/test file hashes to `/tmp/herdr-widget-off-client-baseline.sha256`.

## Task 4: Signed installation with Off selected

- [x] Back up the current installed metadata/signatures and app preference domain privately. Extract only its public signing certificate and match the SHA-1 to a valid local identity; never export private keys.
- [x] Create a private temporary xcconfig using that same identity/team and existing manual signing policy; run installer safety tests.
- [x] Build/install using `XCODE_XCCONFIG_FILE=PRIVATE_PATH ./scripts/install.sh --no-launch`. On failure, do not alter the saved setting or relaunch an unverified build.
- [x] Persist only `widgetUpdatesEnabled = false` in `dev.herdr.menubar`, then launch the newly installed app. Verify unrelated preferences unchanged, installed host/widget hashes match build, strict/deep signatures and entitlements/App Group unchanged, and exactly one installed process.
- [x] Observe at least 65 seconds of native widget-category logs and snapshot mtime/hash: no publication messages or snapshot changes. Verify normal menubar monitoring still runs. The public SDK may still report ghost entries; do not equate this with physical widget presence.
- [x] Remove private signing configuration and extracted public certificate probes, confirm installer lock removed, keep evidence paths, and report Off plus how to re-enable Automatic.

## Execution evidence

- API/compiler red: `/tmp/herdr-widget-off-api-red.log`; behavioral red: `/tmp/herdr-widget-off-behavior-red.log` (77 tests, expected override assertion failures).
- Focused verification: `/tmp/herdr-widget-off-focused-final.log` (93 passed); lifecycle repetitions: `/tmp/herdr-widget-off-lifecycle-repeat.log` (720 passed across 20 iterations).
- Broader scoped suite: `/tmp/herdr-widget-off-scoped-suite.log` (461 passed, excluding only the two independently reproduced baseline failures; not an unfiltered-green result).
- A new cached-session test exposed asynchronous fake-stream delivery versus its one-hour timer. Diagnostic repetitions showed an idle activation snapshot; driving the existing test tick while waiting removed that invalid timing assumption. No production workaround was added.
- Active 10-path SourceKit probe returned no warnings/errors with generated Xcode compilation contexts. Hover resolved the previously stale client member and runtime type. All six temporary contexts were then removed; this is contextual evidence, not a claim of complete ongoing LSP coverage.
- Earlier client, support and protocol-test hashes match the baseline; client remains 997 LOC. `git diff --check` passed.
- Installer safety: `/tmp/herdr-widget-off-installer-tests.log` (30 passed); signed Release build/install: `/tmp/herdr-widget-off-install-build.log`.
- Installation state: `/tmp/herdr-widget-off-install-state.json`; live observation: `/tmp/herdr-widget-off-live-observation.json` and `/tmp/herdr-widget-off-live-logs.json`.
- Installed PID 63203; exact existing certificate/team, metadata, host/widget entitlements and App Group preserved; built and installed binaries match. Only the approved preference changed, including after launch. Four normal Herdr connections were logged.
- Off observation lasted 65.84 seconds: zero widget-category messages/publications/configuration errors, unchanged snapshot hash/mtime, no disconnections or malformed events, one installed process. Two socket-connection failure messages from discovery were observed; no transport behavior was changed in the override scope.
- Private signing/configuration/certificate and preference-backup probes removed; installer lock absent. No commit, push, widget manipulation or shared-cache reset occurred.
