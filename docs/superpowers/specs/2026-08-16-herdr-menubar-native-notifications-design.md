# Herdr Menubar Native Notifications Design

## Summary

Herdr Menubar will deliver opt-in native macOS notifications when an observed agent enters `blocked` or `done`. Notifications will be silent by default, identify the pane and owning Herdr session, and focus the exact Herdr pane and existing WezTerm tab when clicked.

The feature will build on the existing multi-session presentation and selection paths. It will not add notification behavior to Herdr, duplicate session supervision, or create a daemon or helper process.

## Goals

- Notify once when an observed agent enters `blocked` or `done`.
- Notify again when a blocked agent later becomes done.
- Avoid notifications for initial state, repeated snapshots, and reconnect replay.
- Keep panes with the same ID in different Herdr sessions independent.
- Let a notification click reuse the exact session-aware focus path used by a menu row.
- Ask for notification permission only after the user enables notifications in the menu.
- Keep notification sound as a separate, opt-in setting that defaults off.
- Keep Herdr monitoring, the menu badge, and focus behavior working when notification permission or delivery fails.

## Non-goals

- Notifications for `working`, `idle`, unknown statuses, session outages, or reconnection failures.
- A notification on app launch for agents that already need attention.
- Summary notifications, per-session notification settings, schedules, quiet hours, or rate limits.
- Custom notification actions, Dock badges, custom sounds, or provisional authorization.
- Opening a new terminal tab, choosing a fallback session, or focusing a different pane when the target is stale.
- Changes to Herdr's public API or persistence of Herdr runtime state.

## User Experience

### Settings

The status menu will add a Notifications section near the existing Terminal and Launch at Login controls:

- **Notifications** is off by default. Turning it on requests native macOS authorization.
- **Sound** is off by default and disabled while Notifications is off.
- Inline help appears only when authorization fails, is denied, or is later disabled in System Settings.

The initial authorization request will include both alert and sound capabilities. This permits the Sound toggle to work later without changing the app-level default: notification content remains silent until Sound is explicitly enabled.

If the initial authorization request is denied or fails, Notifications remains off. If authorization is granted and later revoked in System Settings, the persisted app-level preference remains on, but the menu explains that macOS is blocking delivery. Authorization state is refreshed whenever the application becomes active.

Turning Notifications off prevents future requests from being delivered. It does not remove notifications already present in Notification Center.

### Notification content

Every qualifying pane transition creates one notification:

- `blocked` uses the title **Agent blocked**.
- `done` uses the title **Agent finished**.
- The body contains the pane's existing visible menu label and the owning session's display name.
- The payload contains a version plus the stable session ID and pane ID required for click routing.

The notification uses the standard macOS sound only when Notifications and Sound are both enabled and macOS permits sound. macOS retains control over Focus modes, notification grouping, banner style, Notification Center history, and user-level sound settings.

When Herdr Menubar is active, including while its menu is open, a new notification may remain in Notification Center but presents without a banner or sound. When the app is inactive, the system applies its normal presentation policy.

### Clicking a notification

Clicking the notification routes the target through the same serialized selection path as clicking a menu row:

1. Focus the pane through the target's owning Herdr session.
2. If WezTerm is selected, locate and activate the existing WezTerm pane for that session.
3. Activate the configured terminal application.
4. Refresh only the target session.

The existing global latest-selection-wins behavior applies across menu clicks and notification clicks. A newer selection supersedes an older pending selection.

If the notification relaunches Herdr Menubar before session discovery finishes, the app holds one pending target until its session connects. It also holds the target while that session is temporarily unavailable within the existing removal grace period. It abandons the target when discovery proves the session is absent, the supervisor removes the session, or Herdr reports that the pane no longer exists. It never opens a replacement tab or focuses a fallback session.

## Architecture

### Accepted approach

Use a dedicated attention-transition coordinator downstream of `AgentStore`'s accepted session state. This avoids putting Apple notification APIs and transition history into the store while also avoiding an independent raw Herdr subscriber that would duplicate discovery and reconciliation.

The major responsibilities are:

1. `AgentStore` remains the owner of accepted multi-session presentation state and serialized selection.
2. `AttentionNotificationCoordinator` owns pane-status history and decides which accepted changes warrant delivery.
3. `NativeNotificationService` owns macOS authorization, settings, local delivery, foreground presentation, and default-action responses.
4. `Preferences` persists the two app-level notification choices.

All production dependencies will be injected behind narrow protocols so transition, store, and UI behavior can be tested without posting real system notifications.

### AgentStore changes

After accepting a `.connected` or `.snapshot` event, `AgentStore` passes the session descriptor and the full current pane presentation to the coordinator. The coordinator never sees stale lifecycle events rejected by the store.

Unavailable and removed events are also forwarded so the coordinator can distinguish a temporary outage from permanent removal. The store continues to derive the menu and badge exactly as it does today.

The row-selection entry point will be generalized around a session-and-pane selection target rather than requiring a currently visible `AgentMenuItem`. Menu rows construct that target from their item; notification responses construct it from their versioned payload. The generalized path retains the existing selection generation, cancellation, exact-session routing, WezTerm focus, activation, refresh, and private error logging.

The store owns a notification-response consumer alongside its supervisor event consumer. Its start/stop tokens and stop barrier cover both consumers. Stop cancels and awaits the response task, clears any pending notification target, and prevents a late response from mutating or restarting a newer lifecycle.

### AttentionNotificationCoordinator

The coordinator keys all history by the composite identity `(SessionID, paneID)`. Each session has a baseline marker plus the last observed status of its panes.

For the first accepted snapshot of a session, the coordinator stores every pane status without notifying. For later snapshots:

- A known pane not previously in `blocked` or `done` notifies when it enters either status.
- A known blocked pane notifies again when it becomes done.
- Repeated `blocked`, repeated `done`, and every transition to a non-attention status remain silent.
- A new pane in an already-baselined session notifies if its first status is blocked or done.
- A pane absent from a later authoritative snapshot is removed from pane history. If it appears again after that, it is treated as a new pane in a baselined session.

The coordinator keeps tracking statuses while app-level notifications are disabled or system delivery is unavailable. Consequently, enabling or re-enabling notifications uses current state as its baseline and never emits existing attention.

Temporary `.unavailable` events preserve status history through the supervisor's existing grace period. A reconnect snapshot is reconciled against that history, preventing replay of unchanged attention. `.removed` permanently deletes the session baseline and all pane history. If the session later returns, its first snapshot is silent.

The coordinator emits an immutable notification event for each qualifying transition. It does not own macOS permission state or click behavior.

### NativeNotificationService

The live service wraps `UNUserNotificationCenter` and installs its delegate during application composition, before synchronization starts. Its interface covers:

- Requesting alert and sound authorization.
- Reading the current authorization, alert, and sound settings.
- Adding a local notification request.
- Producing a stream of validated default-action targets.

Each request has a unique identifier so a later transition for the same pane does not replace an earlier Notification Center entry. Dynamic labels and routing identifiers are placed only in notification content and its versioned payload; any diagnostic logging treats them as private.

The service creates its response stream and bounded buffer before assigning the notification-center delegate. This preserves a default-action response delivered during app relaunch until `AgentStore` begins consuming responses. Malformed payloads, unsupported versions, dismiss actions, and non-default actions are ignored safely.

While the app is active, the delegate returns presentation options that retain Notification Center visibility without a banner or sound. Otherwise, the service lets the scheduled content and macOS settings determine presentation.

### Preferences and permission state

`Preferences` gains two keys:

- `notificationsEnabled`, default `false`
- `notificationSoundEnabled`, default `false`

The stored notification setting expresses app-level intent. The live service separately exposes effective system authorization. Delivery requires both app intent and effective authorization. Sound additionally requires the sound preference and an enabled system sound setting.

The menu's enable operation is asynchronous and serialized so repeated clicks cannot overlap permission requests or leave the toggle in an impossible state. Initial denial leaves the preference off. A later external revocation does not erase the preference; it changes the displayed effective status and suppresses delivery.

As with Launch at Login, `HerdrAppDelegate.applicationDidBecomeActive` triggers a notification-settings refresh so changes made in System Settings appear promptly.

## Data Flow

### Status transition

1. A session client publishes a new authoritative presentation snapshot through `SessionSupervisor`.
2. `AgentStore` validates the current lifecycle and applies the session snapshot.
3. The store forwards the accepted full pane set to `AttentionNotificationCoordinator`.
4. The coordinator updates its per-session history and emits zero or more transition events.
5. If app intent and native authorization permit delivery, `NativeNotificationService` schedules one local request per event, including sound only when enabled.
6. Repeated snapshots update no user-visible notification state.

### Default-action response

1. macOS gives the notification-center delegate the clicked request.
2. `NativeNotificationService` validates and decodes the payload into a session-and-pane target.
3. The target is yielded immediately or buffered until the store's response consumer is ready.
4. `AgentStore` either starts the existing selection flow or keeps the latest target pending until its session connects.
5. A later selection supersedes the pending or in-flight selection through the existing generation and cancellation rules.

## Error Handling and Privacy

- Authorization denial, revoked settings, and authorization errors affect only notification delivery.
- Scheduling errors are logged and do not modify Herdr state, menu state, badge state, or transition history.
- A failed notification click uses the existing transient menu error behavior and does not create a second notification.
- Unsupported payload versions and malformed routing data are ignored.
- Dynamic session names, pane IDs, labels, payload values, and system errors remain private in unified logging.
- Notification content itself is descriptive by explicit user choice and is governed by the user's macOS notification preview settings.

## Testing

### Coordinator unit tests

- First snapshot for every session is silent.
- `idle`, `working`, and unknown to blocked or done notify once.
- Blocked to done notifies again.
- Repeated blocked and done snapshots stay silent.
- Returning to a non-attention status allows a later blocked or done transition to notify.
- New attention panes in a baselined session notify.
- Pane disappearance removes history and qualifying reappearance notifies.
- Duplicate pane IDs in different sessions are independent.
- Temporary unavailability and unchanged reconnect do not duplicate.
- Permanent removal clears the session baseline; its later first snapshot is silent.
- Disabled and unauthorized periods still advance history, so re-enable is silent.

### Native service tests

- Authorization requests exactly alert and sound capabilities.
- Authorized, denied, not-determined, and externally revoked settings map to effective state.
- Sound is omitted by default and included only under both app and system permission.
- Notification title, body, unique request identifier, and versioned payload are correct.
- Foreground presentation includes Notification Center visibility but no banner or sound.
- Default-action responses decode and buffer before subscription.
- Dismissal, malformed data, and future payload versions produce no target.

### AgentStore and UI tests

- Only lifecycle-accepted snapshots reach the coordinator.
- Notification clicks route to the exact session and pane.
- A launch-time click waits for the target session connection.
- A reconnecting target waits through grace; removal cancels it.
- Menu and notification selections share latest-wins serialization.
- Stop and restart cancel, await, and replace response consumers without stale mutation.
- Notifications and Sound default off, persist independently, and render with the correct enabled state.
- Permission success, denial, in-flight serialization, external revocation, and inline help are deterministic.

### Integration and release validation

- Run the complete non-UI test suite and the relevant race-focused repetitions.
- Run Release build and Xcode analysis.
- Install the built application and verify its bundle, signature, and launch/quit behavior.
- With two real Herdr sessions, confirm existing attention is silent; new blocked and done transitions create distinct notifications; default delivery is silent; enabling Sound adds the standard sound; each notification focuses its exact WezTerm pane; and an open menu suppresses banners and sound.
- Confirm no test sockets, helper processes, or notification test artifacts remain.

## Success Criteria

The feature succeeds when the user can opt into native notifications, receive exactly one silent-by-default notification for every newly observed blocked or done transition across all monitored sessions, click any notification to reach that exact existing Herdr/WezTerm pane, and rely on startup, reconnects, repeated snapshots, permission failures, and lifecycle races not to create duplicate alerts or disturb core monitoring.
