# Herdr Menubar Design

## Summary

Herdr Menubar is a native, menu-bar-only macOS companion for Herdr. It provides a persistent, glanceable indication that an agent needs attention, even when the terminal is behind another application or a transient notification was missed.

The application is a presentation client. Herdr remains authoritative for agent lifecycle, semantic status, and whether completed work has been seen.

## Goals

- Show a persistent menu-bar signal when any Herdr agent is blocked or has unseen completed work.
- Show blocked and done agents prominently, with working agents available as quieter context.
- Focus the exact Herdr pane and activate the user's configured terminal when an agent row is selected.
- Recover automatically when Herdr starts, stops, or restarts.
- Support an optional macOS Launch at Login setting.
- Remain small, native, and suitable for personal use or distribution to coworkers running current macOS releases.

## Non-goals

- Reimplementing Herdr's agent detection or status aggregation.
- Maintaining a separate acknowledgement or seen-state database.
- Displaying idle or unknown panes.
- Providing a normal application window or full agent dashboard.
- Supporting older macOS versions.
- Adding third-party dependencies in the initial version.
- Packaging, signing, notarization, Homebrew distribution, or release automation in the initial version.

## User experience

### Menu-bar icon

The icon has three visual modes:

1. **Disconnected:** dimmed when the Herdr socket is unavailable.
2. **Connected, no attention:** normal appearance.
3. **Needs attention:** emphasized appearance with the attention count represented as a badge where the available menu-bar rendering permits it.

The attention count is the number of panes whose public Herdr status is either `blocked` or `done`.

### Menu layout

The menu uses a grouped-detail layout:

1. **Needs Attention**
   - Blocked panes first.
   - Unseen done panes second.
2. **Working**
   - Working panes shown with quieter styling.
3. **Controls**
   - Connection or transient error state when applicable.
   - Terminal application picker.
   - Launch at Login toggle.
   - Retry when disconnected.
   - Quit.

Each agent row mirrors Herdr's agent panel labeling. Its primary label is the workspace display name, with ` · <tab name>` appended when the workspace has multiple tabs. Its secondary context is `<status> · <agent>`. The pane ID remains an internal focus target and is used as visible fallback only when workspace metadata is unavailable. Because native macOS menu rows may suppress secondary text, the primary workspace/tab label must remain independently useful. Idle and unknown panes are omitted.

### Selecting an agent

Selecting an agent row performs these operations in order:

1. Send Herdr's public `pane.focus` request for the selected pane.
2. Require a successful Herdr response.
3. Activate the configured terminal application with `NSWorkspace`.
4. Request a fresh pane snapshot.

Herdr's focus operation owns seen-state changes. In particular, unseen completed work transitions from public `done` to `idle` when Herdr marks it seen. A blocked pane remains blocked, and therefore remains in the attention count, until the agent can continue. The companion does not locally dismiss or acknowledge either state.

If pane focus fails, the app does not activate the terminal and leaves the row visible.

### Terminal preference

The configured terminal defaults to WezTerm. The menu offers a compact picker populated from a curated list of recognized terminal applications that are installed on the Mac. The persisted value is the terminal bundle identifier, not a display-name-only string.

If the configured terminal is unavailable, selecting an agent reports an actionable menu error and prompts the user to choose an installed terminal.

### Launch at Login

Launch at Login is user-controlled and disabled by default. The menu exposes a toggle backed by `SMAppService`. Failure to register or unregister is shown without changing the displayed setting until the system confirms success.

## Architecture

The application uses SwiftUI's `MenuBarExtra` and targets the current macOS SDK.

### `HerdrMenubarApp`

Owns the menu-bar scene and application lifecycle. It creates the shared status store and services. It does not contain protocol or status derivation logic.

### `HerdrClient` actor

Owns socket discovery, Unix-socket connection lifecycle, newline-delimited JSON framing, request correlation, event subscription, and reconnect behavior. Herdr serves one request per ordinary connection and reserves a subscribed connection for its event stream, so the client uses a dedicated long-lived subscription connection plus a short-lived connection for each snapshot or focus request.

The client speaks only Herdr's public socket API. It must tolerate additional response fields and unknown event types for forward compatibility.

### `AgentStore`

An observable main-actor model containing:

- Connection state.
- The latest valid pane snapshot.
- Derived attention and working groups.
- The current transient action error, if any.

It coordinates refreshes and user actions but does not own socket parsing or macOS activation APIs.

### Menu views

SwiftUI views render the icon, grouped sections, rows, settings, and connection state from `AgentStore`. Views issue intents to the store rather than talking directly to Herdr.

### `TerminalActivationService`

Discovers recognized installed terminals and activates the selected bundle identifier through `NSWorkspace`. The recognized-terminal catalog is isolated so new terminals can be added without changing menu or protocol code.

### `LoginItemService`

Wraps `SMAppService` registration state and operations. It exposes system-confirmed state and typed failures to the store.

### Preferences

A small preferences abstraction persists only:

- Selected terminal bundle identifier, defaulting to WezTerm.
- User intent for Launch at Login, while actual registration state continues to come from `SMAppService`.

Agent and pane state is never persisted.

## Connection and synchronization

### Socket discovery

The client follows Herdr's documented public socket path and environment override conventions. Discovery is encapsulated and testable. The app does not inspect Herdr's private TUI client socket.

### Initial connection

During bootstrap, the client:

1. Requests an initial `pane.list` snapshot to discover current pane IDs.
2. Opens the dedicated event connection and subscribes to global pane lifecycle events plus one `pane.agent_status_changed` filter for each current pane ID, matching Herdr's public subscription schema.
3. Waits for the `subscription_started` acknowledgement.
4. Opens a separate short-lived request connection and requests a second, authoritative `pane.list` snapshot.
5. Publishes only the post-subscription snapshot.

Herdr currently scopes status subscriptions to a pane ID. When pane membership changes, the client debounces lifecycle events and replaces the subscription with filters built from a fresh pane snapshot. The replacement subscription becomes authoritative only after acknowledgement and a post-subscription snapshot, preventing membership and status races without polling. One long-lived socket carries all filters; the app does not open one subscription socket per pane.

### Event handling

Events are invalidation signals rather than a second source of pane truth. Relevant status and focus events trigger a coalesced snapshot refresh. Pane membership events trigger a debounced subscription rebuild so the filter set stays synchronized. Multiple events arriving in a short burst produce one refresh or rebuild.

A complete presentation snapshot combines `pane.list`, `workspace.list`, and `tab.list` responses. Workspace and tab metadata are joined to panes by their public IDs to reproduce Herdr's own agent-panel labels. If metadata is briefly unavailable, pane title/label and finally pane ID provide fallbacks.

Using snapshots avoids reconstructing Herdr aggregation, labels, revisions, and seen semantics locally.

### Reconnection

A closed or failed connection changes the store to disconnected while retaining the last snapshot only for internal diagnostics; stale rows are not presented as live agent state.

Reconnect attempts use bounded exponential backoff with jitter. A manual Retry action resets the delay and reconnects immediately. A successful subscription reconnect repeats the complete bootstrap sequence. A failed short-lived request reports its operation failure; a socket-level failure also invalidates the live view and restarts bootstrap so the app cannot present stale state.

Only one subscription connection and one reconnect loop may be active at a time. Short-lived request connections are bounded by refresh coalescing and user actions.

## Error handling

- **Herdr unavailable:** dim the icon and show a disconnected menu with Retry, settings, and Quit.
- **Malformed JSON line:** log and ignore that message; do not discard the last valid snapshot or terminate solely because one line is malformed.
- **Unknown event or field:** ignore it for forward compatibility.
- **Request timeout or socket closure:** fail outstanding requests, transition to disconnected, and begin reconnecting.
- **Snapshot decoding failure:** keep the app disconnected or degraded rather than presenting partially decoded state as authoritative.
- **Pane focus failure:** leave the item visible and show a concise transient error.
- **Terminal unavailable or activation failure:** report the failure after successful Herdr focus and offer terminal selection. Herdr focus is not rolled back.
- **Login-item failure:** retain system-confirmed state and show an error.

Errors use unified macOS logging. User-facing errors are concise and appear in the menu; no modal alerts are required in the initial version.

## Concurrency

Socket ownership and request bookkeeping stay inside `HerdrClient`, implemented as an actor. Observable UI state changes occur on the main actor. Transport callbacks cross into the actor explicitly, and no menu view mutates connection state directly.

Refresh coalescing and reconnect cancellation must be explicit so event bursts or rapid socket failures cannot create overlapping requests or connection loops.

## Testing

### Unit tests

- Decode representative `pane.list`, focus, subscription, and event messages.
- Accept missing optional fields, additional fields, and unknown events.
- Map blocked and done panes into the attention section and count.
- Sort blocked before done with deterministic tie-breaking.
- Put working panes only in the working section.
- Hide idle and unknown panes.
- Default the terminal preference to WezTerm and persist changes.
- Keep Launch at Login UI synchronized with system-confirmed state.
- Ensure terminal activation happens only after successful pane focus.
- Surface missing-terminal and activation failures.
- Verify bounded backoff, cancellation, and manual retry behavior.
- Verify event bursts coalesce into one snapshot refresh.

### Transport tests

A fake Unix-socket Herdr server covers:

- Initial snapshot and event subscription.
- The bootstrap race and final synchronization.
- Newline framing across partial reads and multiple messages per read.
- Request correlation and timeouts.
- Malformed messages and unknown events.
- Disconnect, outstanding-request failure, and reconnection.

### Manual validation

Run the app against a real Herdr session and verify:

- Disconnected, connected-empty, working, blocked, unseen-done, and seen-idle states.
- Multiple agents and workspaces render in stable grouped order.
- Clicking a row focuses the exact pane and activates WezTerm.
- Focusing unseen done work removes it after Herdr reports `idle`.
- Blocked work remains visible until Herdr changes its semantic state.
- Herdr restart reconnects without relaunching the app.
- Launch at Login can be enabled and disabled.

## Initial project structure

```text
herdr-menubar/
├── HerdrMenubar.xcodeproj/
├── HerdrMenubar/
│   ├── App/
│   ├── Herdr/
│   ├── Menu/
│   ├── Status/
│   └── System/
├── HerdrMenubarTests/
└── docs/superpowers/specs/
```

Exact file names belong in the implementation plan. The boundaries above are requirements: transport, observable state, views, terminal activation, and login-item behavior remain independently testable.

## Success criteria

The first version succeeds when a user can leave Herdr behind other applications, glance at the macOS menu bar, reliably see whether any agent is blocked or newly done, open the grouped menu for context, and select an item to reach the exact Herdr pane in their configured terminal without the companion inventing state separate from Herdr.
