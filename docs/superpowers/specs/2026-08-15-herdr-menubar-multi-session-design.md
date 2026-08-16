# Herdr Menubar Multi-Session Monitoring Design

**Date:** 2026-08-15

## Summary

Herdr Menubar will automatically discover every active Herdr session and present one aggregate attention view. The menu-bar badge will count blocked and newly completed agents across all connected sessions. The menu will remain status-first, with agents grouped by session inside **Needs Attention** and **Working**.

The implementation will add a session supervisor that owns one existing-style `HerdrClient` per discovered socket. Each client remains an independent connection, subscription, refresh, focus, and reconnect state machine. A failure or restart in one session must not hide or invalidate healthy sessions.

This project has one user and does not require compatibility with the existing single-session environment-selection behavior. Production discovery replaces `HERDR_SESSION` and `HERDR_SOCKET_PATH`; they will no longer choose or override the monitored session set.

## Goals

- Discover the default Herdr session and all named sessions automatically.
- Add sessions that start while Herdr Menubar is running.
- Remove stopped named or default sessions after a short grace period.
- Aggregate attention into one accurate menu-bar count.
- Preserve status-first presentation while making session ownership clear.
- Route focus and refresh actions to the exact owning session.
- Isolate connection, restart, and protocol failures to one session.
- Keep a single global terminal preference and Launch at Login setting.

## Non-goals

- macOS notifications, sounds, or notification permissions.
- User controls for including, excluding, pinning, or renaming sessions.
- Different terminal preferences per session.
- Persisting session, pane, agent, or connection state.
- Adding or changing Herdr's public socket API.
- Multiple menu-bar icons.
- Compatibility with `HERDR_SESSION` or `HERDR_SOCKET_PATH` as production selection mechanisms.

## Session discovery

### Public locations

The discovery service derives Herdr's configuration root from non-empty `XDG_CONFIG_HOME`, otherwise `~/.config`, then reconciles these shallow locations:

```text
<config-root>/herdr/herdr.sock
<config-root>/herdr/sessions/<name>/herdr.sock
```

The root socket identifies the **Default** session. A direct child directory of `sessions` identifies a named session using its final path component. A valid session name is any non-empty direct-child component other than `.` or `..`; path separators cannot occur inside one component. Discovery ignores deeper descendants, non-directory direct children, and candidates whose `herdr.sock` entry is not a Unix-domain socket.

Discovery runs at startup and then approximately every two seconds. Periodic reconciliation is preferred to filesystem-event-only discovery because the directory may not exist at launch, sockets are replaced during restarts, and filesystem events may be coalesced. Scanning one shallow local directory is inexpensive and deterministic.

Tests may inject an alternate discovery root and fixed socket descriptors. Production does not inspect Herdr's private TUI socket or shell environment variables that select only one session.

### Stable identity

`SessionID` is a value type derived from session kind and name, not from a client instance:

- `.default`
- `.named(String)`

`SessionDescriptor` contains the stable ID, display name, and absolute socket URL. The default display name is `Default`; named sessions use their directory name. Session identity remains stable when a socket file is replaced at the same public path.

### Reconciliation and grace period

`SessionSupervisor` compares each discovery result with its owned runtime dictionary:

- A new socket descriptor creates and starts one client runtime.
- An existing descriptor is idempotent and does not create another client.
- A socket replaced at the same path keeps the runtime and reconnects through its client.
- A missing descriptor marks the runtime absent and starts a ten-second grace period.
- Reappearance during the grace period cancels removal and triggers an immediate retry.
- Continued absence through the grace period stops the client, cancels its tasks, and removes the runtime.

The last snapshot is excluded as soon as a session disconnects or its socket disappears. The grace period prevents menu churn during quick restarts; it never permits stale attention to contribute to the badge.

If a socket path remains present but cannot connect, the runtime stays discovered and reconnecting rather than being repeatedly removed and recreated. It appears as unavailable in the menu's connection-status area until it connects or the socket disappears and expires.

## Architecture

### `SessionDiscovery`

A small filesystem-facing component returns the current `[SessionDescriptor]`. It owns path derivation and entry validation but no timers, clients, or UI state. Its filesystem dependency is injectable for hermetic tests.

### `SessionSupervisor`

An actor owns the discovery loop and a dictionary of `SessionRuntime` values keyed by `SessionID`. Each runtime contains its descriptor, one `HerdrClient`, event-consumption task, runtime generation, candidate-presence state, and optional grace-removal task.

The supervisor is the only unit allowed to add or remove session runtimes. It exposes a single aggregate event stream and session-qualified commands:

```swift
func events() -> AsyncStream<SessionSupervisorEvent>
func start() async
func stop() async
func retryUnavailable() async
func focus(sessionID: SessionID, paneID: String) async throws -> PaneInfo
func refresh(sessionID: SessionID) async
```

Supervisor events describe lifecycle and authoritative presentation state. Every successful reconciliation publishes `discoverySnapshot`, including an empty array. That authoritative event lets the store distinguish a completed empty scan from startup before the first successful scan or a discovery failure:

```swift
enum SessionSupervisorEvent: Sendable {
    case discoverySnapshot([SessionDescriptor])
    case connected(SessionDescriptor, PresentationSnapshot)
    case snapshot(SessionID, PresentationSnapshot)
    case unavailable(SessionID, String)
    case removed(SessionID)
}
```

Each client still owns exactly one socket path, long-lived subscription, short-lived request connections, snapshot bootstrap, reconnect loop, and subscription rebuild behavior. A fixed-path resolver or equivalent client initializer replaces production environment-based socket selection.

### `AgentStore`

The main-actor store consumes supervisor events and maintains session-indexed presentation state. Each entry contains the descriptor, connection state, and most recent authoritative menu items. A disconnected or unavailable event clears only that session's items. The store also records whether it has received its first successful `discoverySnapshot`. This snapshot reports currently present socket descriptors but does not directly delete store entries: grace-period sessions remain unavailable until the supervisor emits `removed`. An empty snapshot produces **No Herdr sessions running** only when the store has no retained grace-period entries.

The store derives aggregate menu sections and the attention count. It does not scan the filesystem, own clients, parse protocol messages, or retain stale snapshots.

### App composition

`HerdrMenubarApp` creates one discovery service, one supervisor, and one store. On startup, the store obtains the supervisor event stream and starts its aggregate-event consumer before starting the supervisor, so initial and empty reconciliation events cannot be lost. On termination, the store cancels and awaits its event consumer, then stops the supervisor; the supervisor cancels discovery and grace tasks, stops every child client, and awaits their cleanup before macOS terminates the app.

## Presentation model

### Composite identity

Pane, workspace, and tab IDs are only unique inside one Herdr session. Every actionable menu item therefore has the composite identity `(SessionID, paneID)`. SwiftUI identity, selection routing, sorting tie-breakers, and test fixtures must all use the composite identity.

### Status-first menu

The menu retains two top-level sections:

```text
NEEDS ATTENTION
  DEFAULT
    Herdr Menubar · Pi
  CLIENT-WORK
    API · Claude

WORKING
  DEFAULT
    dotfiles · Pi
  EXPERIMENT
    server · Codex
```

Rules:

- **Needs Attention** contains `blocked` and `done` agents from connected sessions.
- **Working** contains `working` agents from connected sessions.
- Session subgroups with no items for that status are omitted.
- The default session sorts first; named sessions sort case-insensitively by display name with `SessionID` as the stable tie-breaker.
- Existing blocked-before-done and label ordering apply within each session.
- Existing workspace, tab, and agent row-label construction remains unchanged.
- A single session is still shown beneath its session subgroup; no single-session compatibility mode is required.

The menu-bar badge is the total number of attention items from connected sessions. A session never contributes its last-known count while unavailable.

### Connection presentation

If at least one session is connected, the icon remains active and all healthy data stays visible. Unavailable discovered sessions and sessions inside the grace period appear in a compact connection-status area such as `client-work — reconnecting`.

The icon is dimmed only when zero sessions are connected. Empty-state messages are:

- **No active agents** when at least one session is connected but no session has visible attention or working agents.
- **No Herdr sessions running** when discovery finds no sessions and all grace periods have expired.
- **Connecting to Herdr sessions…** when descriptors exist but none has completed bootstrap.

When at least one session is unavailable, the menu offers one **Retry Unavailable Sessions** action. It forces immediate discovery and resets reconnect backoff only for unhealthy runtimes.

## User actions

Selecting an agent performs this sequence:

1. Use the item's `SessionID` to locate the owning runtime.
2. Send `pane.focus` with its `paneID` through that runtime's client.
3. Require a successful Herdr response.
4. Activate the globally configured terminal application.
5. Refresh only the owning session.

Failure to find the runtime or focus the pane does not activate the terminal. The visible error includes the session display name so duplicate workspace or pane labels are diagnosable. Terminal activation failures retain the current behavior and do not affect other sessions.

## Failure handling and concurrency

- The supervisor actor serializes discovery reconciliation and runtime ownership.
- Each `HerdrClient` actor serializes one session's transport and synchronization state.
- `AgentStore` changes observable presentation state only on the main actor.
- A per-runtime generation token rejects events from clients that have been removed or replaced.
- Discovery failures are logged and retried without stopping healthy runtimes.
- Every successful discovery reconciliation publishes an authoritative descriptor snapshot, even when empty; failed scans publish no snapshot and cannot masquerade as an empty result.
- Failure in one client's transport, bootstrap, metadata request, subscription, or focus operation changes only that session's state.
- A session contributes data only after the existing authoritative bootstrap completes.
- Repeated discovery results, disconnect events, retry commands, and removal requests are idempotent.
- `stop()` cancels the discovery loop and grace tasks, stops all clients, ends event consumers, and prevents late events from repopulating the store.

Dynamic socket paths, session names, focus details, and errors remain private in unified logging.

## Testing strategy

### Discovery tests

- Discover a root socket as `.default` with display name `Default`.
- Discover multiple direct named-session sockets.
- Use non-empty `XDG_CONFIG_HOME` as the configuration root.
- Accept any non-empty direct-child session name other than `.` or `..`.
- Ignore missing roots, ordinary-file direct children, directories without Unix-domain sockets, and deeper descendants.
- Publish a successful empty discovery snapshot when no session sockets exist.
- Do not publish an empty snapshot when filesystem discovery fails.
- Produce deterministic descriptors and ordering across repeated scans.
- Do not use `HERDR_SESSION` or `HERDR_SOCKET_PATH` to limit production discovery.

### Supervisor tests

- Create one client per newly discovered descriptor.
- Do not duplicate clients during repeated reconciliation.
- Add a named session while the supervisor is running.
- Clear a session snapshot immediately when it becomes unavailable.
- Recover the same runtime when its socket returns within the grace period.
- Stop and remove a runtime after grace expiry.
- Keep a present but unreachable socket in reconnecting state.
- Reject late client events after removal using the runtime generation.
- Keep healthy session events flowing when another session fails.
- Retry only unavailable sessions and run discovery immediately.
- Stop all runtimes and tasks deterministically.
- Deliver the first discovery snapshot only after the store has subscribed.

Tests inject a manual clock or short controllable durations; they do not wait for real two- or ten-second intervals.

### Store and menu-model tests

- Treat identical pane IDs in different sessions as distinct items.
- Aggregate attention counts across connected sessions.
- Group status first and session second.
- Sort Default first, then named sessions, then items using existing status and label rules.
- Clear only the unavailable session's items.
- Derive active, partially unavailable, connecting, and no-session states.
- Distinguish an authoritative empty discovery snapshot from startup before a successful scan.
- Route focus and refresh to the selected item's owning session.
- Include the session name in focus errors.

### Multi-server integration tests

Use two simultaneous fake Unix-domain Herdr servers to prove:

- Both sessions bootstrap and publish snapshots.
- Events and refreshes update only their owning session.
- Stopping one server does not invalidate the other.
- Restarting one server within the grace period restores it without duplication.
- Identical pane IDs remain separately actionable.
- `pane.focus` reaches only the selected session's server.

### Final validation

Run the non-UI unit suite, a Release build, static analysis, and a bounded ordinary-app launch. In the ordinary app, start a default and named Herdr session and confirm aggregate counts, grouping, focus routing, independent restart behavior, grace-period removal, retry, and all three empty states.

## Documentation changes

Update the README to describe automatic multi-session discovery, status-first session grouping, aggregate attention count, grace behavior, and removal of environment-based single-session selection. Retain the statement that Herdr is the source of truth and that no agent or session state is persisted.

## Acceptance criteria

- Starting Herdr Menubar while multiple sessions are active shows all of them after bootstrap.
- A successful initial scan with no sockets produces **No Herdr sessions running**; a failed or not-yet-completed scan does not.
- Starting a new named session while the app runs adds it without restarting the app.
- Attention count equals the sum of current `blocked` and `done` agents across connected sessions.
- Duplicate pane IDs in separate sessions render and focus independently.
- A failed or stopped session never clears, dims, blocks, or misroutes a healthy session.
- A quick session restart reconnects during the ten-second grace period without duplicate groups.
- A session absent beyond the grace period disappears and no longer contributes UI state.
- A single Retry action targets unavailable sessions without disrupting connected ones.
- With no connected sessions, the icon and empty-state text accurately distinguish connecting from no sessions running.
- No notifications, selection controls, per-session terminal preferences, or persisted runtime state are introduced.
