# Herdr Menubar Global Keyboard Shortcuts Design

**Date:** 2026-08-27

## Summary

Herdr Menubar will add two user-configurable global keyboard shortcuts:

- **Toggle Herdr Menu** opens the status menu when it is closed and closes it when it is open.
- **Focus Latest Notification** acts like clicking the most recently delivered Herdr notification.

Both shortcuts are unassigned by default and are configured in a small **Keyboard Shortcuts…** window opened from the status menu. Shortcut assignments persist, but the latest notification target exists only in memory for the current app run.

The feature will replace only the current SwiftUI `MenuBarExtra` shell with an AppKit-owned status item and native menu. Existing session supervision, aggregate presentation, notification delivery, exact Herdr/WezTerm focus, and latest-selection-wins behavior remain authoritative.

SSH integration is intentionally a separate design. This feature keeps notification targets opaque and routes them through the existing selection boundary so a later host-qualified target can use the same shortcut without coupling shortcut code to local session identity.

## Goals

- Let the user configure, replace, clear, and persist two global shortcuts.
- Keep both shortcuts unassigned until the user explicitly records them.
- Toggle the actual Herdr status menu open and closed from any application.
- Focus the exact session and pane from the newest successfully delivered notification.
- Reuse the notification-click selection path, including exact WezTerm focus, latest-wins serialization, reconnect grace, and no-fallback behavior.
- Allow repeated presses of the latest-notification shortcut to refocus the same target until a newer notification is delivered.
- Require no Accessibility or Input Monitoring permission.
- Preserve the current native menu appearance, grouping, settings, errors, status icon, and actions.

## Non-goals

- Shipping default shortcut assignments.
- Adding a shortcut for every visible agent, session, status, or menu action.
- Persisting notification targets across app launches.
- Choosing a fallback pane or session when the latest target is gone.
- Opening a new terminal tab or Herdr client.
- Implementing a general macro system, shortcut sequences, or per-profile shortcuts.
- Guaranteeing detection of shortcuts owned privately by every other application; macOS does not expose a complete global registry.
- Adding Accessibility-based menu clicking or synthetic mouse events.
- Implementing SSH transport, remote host settings, or remote reconnect UX in this feature.

## User Experience

### Status menu

The existing menu gains one item near the other application settings:

```text
Keyboard Shortcuts…
```

Choosing it opens a small, ordinary macOS window containing two shortcut recorders:

- **Toggle Herdr Menu**
- **Focus Latest Notification**

The window explains that both shortcuts work globally and that the latest-notification action applies only to notifications delivered during the current app run. Closing the window does not stop monitoring or unregister saved shortcuts.

### Recording shortcuts

Each recorder initially displays no assignment. Recording a valid combination saves and activates it immediately. Recording a replacement unregisters the old listener before the new listener becomes active. Clearing a recorder removes the persisted assignment and unregisters it immediately.

A shortcut that conflicts with the other Herdr shortcut or with a conflict the recorder can identify is rejected without replacing the prior valid assignment. The recorder presents the package's standard validation explanation. If macOS rejects global registration because another application owns the combination, an assignment controller detects that the saved candidate is inactive, restores the prior valid assignment, and presents concise inline feedback even when the owning application cannot be named.

### Toggle Herdr Menu

Pressing the configured menu shortcut:

- opens the menu from the status item when it is closed;
- closes it through normal menu cancellation when it is open;
- works while another application is active;
- interoperates with mouse opening and closing; and
- treats rapid repeated presses as toggles without creating duplicate menus or leaving stale open-state bookkeeping.

The opened menu is the same native menu shown by clicking the menu-bar item. Keyboard navigation, VoiceOver semantics, highlighted rows, submenus, and standard dismissal behavior remain AppKit-managed.

### Focus Latest Notification

After macOS accepts delivery of a Herdr notification request, its exact `NotificationSelectionTarget` becomes the in-memory latest target. A later logically newer accepted notification replaces it. Delivery failure, disabled notifications, denied authorization, disabled system alerts, initial baselines, and suppressed transition events do not update the target.

Pressing the configured shortcut routes that target through the same `AgentStore` selection entry point used by a notification click:

1. Focus the pane through its owning Herdr session.
2. If WezTerm is selected, focus the exact existing attached WezTerm pane.
3. Activate the configured terminal application.
4. Refresh only the owning session.

The target is not consumed. Repeated presses refocus the same pane until a newer notification is successfully delivered. If no notification has been delivered during the current app run, the action is a silent no-op.

If the owning session is temporarily unavailable, the target is held through the supervisor's existing ten-second removal grace, exactly like a notification click received during reconnection. A newer menu click, notification click, or latest-notification shortcut press participates in the existing global latest-selection-wins behavior. Removal or authoritative absence abandons the target; the app never selects another pane or session as a fallback.

## Selected Approach

### AppKit status item plus `KeyboardShortcuts`

Use an AppKit `NSStatusItem` and `NSMenu` for the menu shell, and the open-source `KeyboardShortcuts` Swift package for global registration and recorder UI. The package is added as an exact Swift Package dependency and exposes only the two named application shortcuts.

This approach is selected because:

- AppKit owns supported programmatic menu presentation and cancellation.
- Native `NSMenu` preserves menu behavior without Accessibility automation.
- `KeyboardShortcuts` provides a purpose-built Swift recorder, persistence, registration, conflict handling, and lifecycle behavior without permission prompts.
- The package supports shortcuts while an `NSMenu` is tracking, which is required for toggle-to-close.

The alternatives were rejected:

- **AppKit status item plus custom Carbon registrar and recorder:** viable, but it recreates key-code translation, modifier display, persistence, conflict behavior, and lifecycle code already provided by a focused dependency.
- **Keep `MenuBarExtra` and simulate a click:** SwiftUI exposes no supported programmatic open/close API for the current menu-bar scene. Mouse-coordinate or Accessibility automation would be fragile and would introduce an inappropriate permission requirement.

## Architecture

### Application composition

`ApplicationRuntime` becomes the explicit `@MainActor` composition and lifecycle owner. `HerdrAppDelegate` constructs and strongly retains exactly one runtime. The SwiftUI `App` installs that delegate through `NSApplicationDelegateAdaptor` and supplies an inert `Settings { EmptyView() }` scene solely to satisfy the `App` scene contract; it no longer owns startup work through a view `.task`.

The runtime retains three application-lifetime controllers:

1. `StatusItemController` owns the `NSStatusItem`, `NSMenu`, menu delegate state, and native menu actions.
2. `GlobalShortcutController` binds the two named shortcuts to injected actions.
3. `KeyboardShortcutSettingsWindowController` owns one reusable settings window hosting the SwiftUI recorder view.

`AgentStore`, `Preferences`, `NotificationSettingsController`, `LoginItemService`, and the installed-terminal catalog remain single shared instances owned by the runtime. The app delegate's runtime stop barrier is authoritative during termination.

`applicationDidFinishLaunching` calls the runtime's idempotent `start()` method. Startup ordering is:

1. Construct the existing monitoring and notification graph.
2. Construct the latest-target store and inject it into notification coordination.
3. Install the status item and menu.
4. Register any persisted shortcuts.
5. Install application delegate references and refresh settings.
6. Arm runtime-owned model observation.
7. Start `AgentStore` synchronization outside tests.

`applicationDidBecomeActive` asks the runtime to refresh login, notification, and unavailable-shortcut state. `applicationShouldTerminate` returns `.terminateLater`, starts exactly one runtime stop, and replies only after it completes. Shutdown first invalidates the runtime lifecycle token, cancels and awaits both shortcut event consumers, closes menu tracking and the settings window, cancels model observation, resets the latest target, and then awaits the existing store shutdown. No shortcut callback may start selection or reopen UI after shutdown begins. Repeated start and stop calls are idempotent, and a start cannot overtake an in-flight stop.

### `StatusItemController`

`StatusItemController` is `@MainActor` and owns exactly one variable-length `NSStatusItem`. It derives button appearance and accessibility text from the existing `MenuBarIconPresentation` and `MenuBarIcon.accessibilityValue` logic so disconnected, clear, and attention-count states retain their meaning.

The controller rebuilds or updates its `NSMenu` from an immutable presentation snapshot derived from the same observable state currently consumed by `StatusMenu`:

- attention sections and session-qualified agent rows;
- working sections;
- connection and reconnecting state;
- transient errors;
- terminal selection;
- Launch at Login state and help;
- Notifications and Sound state and help;
- retry action;
- **Keyboard Shortcuts…**; and
- Quit.

Native menu-item represented objects or stable action tokens carry exact session-and-pane identity. Dynamic session names and pane labels are presentation only and are never used for routing.

`ApplicationRuntime` installs a re-arming `withObservationTracking` adapter on the main actor. Every observation pass reads all store and settings fields needed for the icon and menu into one immutable snapshot, applies status-item icon and accessibility changes immediately, and caches the newest menu snapshot. When the menu is not tracking, the controller may rebuild immediately. While it is tracking, structural mutation is deferred and only a dirty flag is set. `menuWillOpen` applies the newest snapshot before display; `menuDidClose` applies any snapshot that became dirty while tracking. Shutdown invalidates observation ownership so a queued re-arm cannot retain or mutate a stopped runtime.

The menu controller implements `NSMenuDelegate` and records open state only from `menuWillOpen` and `menuDidClose`. Its shortcut action runs on the main actor:

- if open, call `cancelTracking()` on the owned menu;
- if closed, invoke `statusItem.button?.performClick(nil)` so the owned button performs its normal attached-menu action.

It does not infer state from key presses or mouse events. AppKit delegate callbacks remain the source of truth when the user opens, dismisses, or switches away from the menu.

The existing SwiftUI `StatusMenu` shell is removed after parity tests cover all menu content and actions. Reusable presentation helpers and models may remain SwiftUI-independent; monitoring and selection logic do not move into the controller.

### `GlobalShortcutController`

The controller defines two stable `KeyboardShortcuts.Name` values with no default shortcuts. It owns one package `events(for:)` consumer per name, filters for key-up events, and injects closures rather than retaining business logic:

- `toggleMenu` calls `StatusItemController.toggleMenu()` on the main actor.
- `focusLatestNotification` asks the target store for its current value and passes it to the store's target-selection entry point.

The two event-consumer tasks are installed once per runtime generation even when no shortcut is assigned. The package registers and unregisters the underlying Carbon hotkey as the saved value changes. App activation does not duplicate consumers; controller shutdown cancels and awaits both streams. Callback arrival during shutdown or before composition completes is ignored through the runtime lifecycle token.

`ShortcutAssignmentController` wraps the package's `getShortcut`, `setShortcut`, `isEnabled(for:)`, validation, and change notifications behind a testable registrar seam. It remembers the last known-good value for each name. Known system/menu conflicts and duplication between the two Herdr shortcuts are rejected by recorder validation before saving. After a non-empty candidate is saved, the controller checks `isEnabled(for:)`, which verifies that a handler-backed Carbon registration exists. If registration failed, it immediately restores the remembered prior value and publishes an inline unavailable message. If the prior value is empty, rollback clears the failed candidate. Clearing intentionally skips this enabled check.

At startup, a persisted assignment that cannot currently register remains persisted and visible but is reported as unavailable; there is no fabricated prior value to restore. Application activation makes one bounded re-registration attempt and clears the error only after `isEnabled(for:)` succeeds. The package owns persisted key code and modifier values in `UserDefaults`. Herdr Menubar does not persist human-readable keystrokes or duplicate the package's storage.

### Settings window

`KeyboardShortcutSettingsWindowController` retains one `NSWindow` containing a SwiftUI `KeyboardShortcutSettingsView`. Repeated menu actions bring the existing window forward rather than create duplicates. The window uses standard title-bar closing, is released only with the application controller, and does not change the app's agent/menu-bar activation policy.

The SwiftUI view uses the package's recorder controls for the two stable names. A small validation layer prevents the two Herdr actions from retaining the same combination and preserves the prior valid assignment when a new recording is rejected. Recorder validation uses the package's standard explanatory alert; post-save Carbon registration failures appear as inline status in the window. The recorders expose explicit clear controls and accessible labels.

### Latest notification target

`LatestNotificationTargetStore` owns zero or one logical delivery ordinal and `NotificationSelectionTarget`. It is in-memory, concurrency-safe, and has only three operations:

- conditionally record an accepted target and ordinal when the ordinal is newer than the current accepted ordinal;
- read the current target for a shortcut press; and
- reset during application teardown.

`NativeNotificationServing.deliver` returns an explicit `NotificationDeliveryResult`: `.accepted` only after `UserNotificationCenterBacking.add` completes, or `.suppressed` when current authorization or alert settings prevent submission. Thrown scheduling failures remain failures. The coordinator records only `.accepted`.

`AttentionNotificationCoordinator` receives the target store behind a narrow recording protocol. Before its first delivery suspension for a reconciliation, it synchronously creates the complete ordered candidate-event list and assigns a monotonic ordinal to every candidate. This prevents actor reentrancy from changing logical source order. After each delivery returns `.accepted`, the coordinator asks the store to record the target with its ordinal. The store's monotonic comparison prevents an older slow delivery completion from overwriting a newer accepted event. A cancellation observed after `.accepted` does not skip that record. `.suppressed` and thrown delivery never advance the store's accepted ordinal.

The shortcut controller treats the target as opaque. It neither inspects `SessionID` nor caches a menu row. This keeps the shortcut compatible with a future host-qualified remote target.

### Shared target selection

`AgentStore` exposes one internal target-selection entry point used by both the notification response consumer and the latest-notification shortcut. Menu rows continue to create targets from their stable item identity or call an equivalent wrapper.

The shared path preserves all existing behavior:

- a connected target starts the serialized exact-session selection immediately;
- a temporarily unavailable target becomes the one pending target through grace;
- a target not yet observed may wait until completed discovery proves absence;
- authoritative absence or `.removed` abandons it with the existing transient error;
- newer selections cancel or supersede stale work; and
- stop invalidates and awaits selection before supervisor shutdown.

Repeated shortcut presses do not build a queue. Each press is a new latest selection for the same immutable target.

## State and Lifecycle

### Persisted state

Only the two shortcut assignments persist, using the package's `UserDefaults` representation. They are independent: either, both, or neither may be assigned.

### In-memory state

- status-item and menu open state;
- one settings window controller;
- one latest successfully delivered notification target;
- active shortcut callback lifecycle tokens; and
- existing store selection and pending-target state.

The latest target is empty at every process launch even when Notification Center still contains older Herdr notifications. Clicking an old notification continues to route its own payload normally, but the keyboard shortcut does not learn from that click unless a new notification is delivered in the current run.

### Races

- **Delivery versus shortcut press:** a press reads either the prior complete target or the newly recorded complete target; no partial state exists. A gated older completion cannot overwrite a logically newer accepted ordinal.
- **Notification click versus shortcut press:** both enter the existing selection generation; the later accepted selection wins.
- **Menu row versus shortcut press:** the same global latest-selection-wins rule applies.
- **Reconnect versus press:** the store retains one exact pending target through grace and never falls back.
- **Reassignment versus key callback:** lifecycle identity rejects callbacks owned by the retired registration.
- **Open/close versus mouse dismissal:** only AppKit menu-delegate callbacks change the recorded open state.
- **Stop versus callback:** shutdown invalidates shortcut ownership before awaiting store stop, so no late callback mutates a newer lifecycle.

## Error Handling and Privacy

- Pressing Focus Latest Notification with no current-run target is silent.
- A target held during reconnection does not produce an immediate error; permanent removal uses the existing session-qualified transient error shown on the next menu open.
- A stale pane, Herdr focus failure, partial WezTerm-control failure, terminal activation failure, and refresh behavior remain exactly as defined by the existing selection path.
- No focus fallback, tab creation, or session substitution occurs.
- A recorder-detected shortcut conflict leaves the previous valid assignment active and uses the package's standard explanation.
- If macOS refuses a newly recorded global registration, post-save verification rolls back to the prior valid assignment and displays a settings-window error. A persisted startup assignment that is currently unavailable remains visible and is retried on application activation.
- Dynamic session names, pane IDs, labels, notification targets, shortcut event details, and underlying system errors remain private in unified logging.
- Persisted shortcut data contains only the package's key code and modifier representation. Notification targets are never persisted.
- The feature requests neither Accessibility nor Input Monitoring permission and performs no event tap, synthetic click, shell invocation, or keyboard-content capture.

## Testing

### Shortcut configuration tests

- Both names are unassigned on first launch with empty defaults.
- Recording, replacing, clearing, and reloading each assignment behaves independently.
- Replacing causes the package to unregister the old Carbon hotkey before registering the candidate while retaining exactly one event consumer.
- A conflict between the two Herdr actions is rejected while preserving the prior valid assignment.
- A post-save `isEnabled(for:)` failure restores the prior valid assignment and exposes concise inline help.
- A failed first assignment rolls back to unassigned.
- A persisted startup assignment that cannot register remains visible, reports unavailable, and retries without duplicating consumers on application activation.
- Repeated app activation and controller refresh do not duplicate callbacks.
- Controller shutdown removes callbacks and ignores late events.

The package is wrapped behind a narrow registrar seam. Unit tests use a deterministic fake rather than installing real global hotkeys.

### Status item and menu tests

- The status item derives disconnected, clear, attention, count, opacity, and accessibility presentation from existing models.
- The native menu preserves attention-first grouping, session headings, working items, reconnecting state, connection labels, errors, terminal choices, login state, notification toggles, retry, settings, and Quit.
- Every agent item routes its stable session and pane rather than its label.
- Menu actions invoke exactly their existing service or store operations.
- A closed-menu shortcut press opens once; an open-menu press cancels tracking once.
- Rapid alternating presses leave state equal to the final AppKit delegate callback.
- Mouse-open followed by shortcut-close and shortcut-open followed by mouse-dismiss both reconcile correctly.
- Reopening while settings change reflects current observable state without restarting monitoring.
- Observation re-arms after every relevant model change, refreshes the icon immediately, and cannot mutate after runtime shutdown.
- Menu structure is not mutated during tracking; a dirty snapshot is applied on close and before the next open.

The menu-presentation builder and status-item driver are protocol-backed so these tests do not depend on clicking the user's real menu bar.

### Latest-target tests

- Only a successfully delivered notification records a target.
- `.accepted` is returned only after the backend add succeeds; disabled delivery, authorization rejection, disabled system alerts, `.suppressed`, service failure, baseline reconciliation, and repeated attention state do not change the target.
- A newer successful delivery atomically replaces the older target.
- An older gated delivery that completes after a newer accepted event cannot overwrite the newer ordinal.
- Multiple sessions with duplicate pane IDs remain distinct through the composite target.
- Repeated shortcut presses reuse the same target.
- No current-run target performs no store operation and publishes no error.
- App teardown clears the target; relaunch does not restore it from defaults or Notification Center.

### Store orchestration tests

- Notification response and shortcut target use the same exact-session selection entry point.
- A connected shortcut target follows the existing Herdr focus, WezTerm focus, application activation, and owning-session refresh order.
- An unavailable target survives repeated omission snapshots during grace and runs once on reconnect.
- `.removed` and authoritative absence abandon the pending target without fallback.
- A newer menu selection, notification click, or shortcut press supersedes stale selection work.
- Repeated presses do not queue multiple future selections during reconnection.
- Stop cancels and awaits in-flight selection; restart accepts only callbacks from the new lifecycle.
- Application runtime start/stop tests prove the delegate launch hook replaces the removed view task, shortcut and observation consumers are canceled before store stop, settings/menu close, and a restart cannot overtake shutdown.

Race tests use explicit gates and observable barriers rather than sleeps or fixed `Task.yield()` counts.

### Integration and release validation

- Run focused shortcut, menu, notification, store, and selection suites with race-sensitive repetitions.
- Run the complete non-UI suite, Swift concurrency diagnostics, Release build, and Xcode analysis.
- Install the built app and verify bundle, signature, launch, normal Quit, and absence of helper processes.
- Assign temporary global shortcuts and verify each works while another application is active.
- Verify the menu shortcut opens and closes the real native menu, including mouse/shortcut interoperability.
- With two real Herdr sessions in two WezTerm tabs, deliver notifications for each and prove the latest shortcut focuses only the newest exact session and pane.
- Press the latest shortcut repeatedly, replace the latest notification, and verify the target changes only after accepted delivery.
- Disconnect and reconnect the owning session inside grace and verify the exact pending target resumes without fallback.
- Clear both assignments after the smoke test and confirm no shortcut remains registered.

SSH transport receives its own unit, tunnel, host-key, reconnect-confirmation, multi-session, and real-work-host validation in a separate design.

## Dependency and Compatibility

Add [`sindresorhus/KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) as an exact Swift Package dependency at the reviewed release (3.0.1 at design time). Commit `Package.resolved` or the Xcode project's equivalent pin so builds are reproducible. The dependency is used only for recording, persistence, conflict reporting, and registration; it does not own menu, notification, session, or selection state.

The feature targets the project's existing macOS deployment and Swift versions. Backward compatibility with prior internal `MenuBarExtra` composition is not required because this is a single-user application, but visible menu behavior and saved non-shortcut preferences must migrate unchanged.

## Success Criteria

The feature succeeds when the user can leave both shortcuts unassigned or configure either one, globally toggle the real Herdr menu without permissions or synthetic input, and repeatedly focus the exact target of the newest notification delivered during the current app run. Existing monitoring, aggregation, notifications, WezTerm focus, reconnect grace, selection ordering, privacy, and shutdown behavior must remain intact.
