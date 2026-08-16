# Herdr Menubar WezTerm Session Focus Design

**Date:** 2026-08-15

## Summary

Herdr Menubar already routes a selected agent row's `pane.focus` request to the correct Herdr session. It then activates WezTerm through macOS, but generic application activation cannot select the existing WezTerm tab that contains that session's attached Herdr client. With two Herdr sessions attached in two WezTerm tabs, the internal Herdr pane changes while WezTerm remains on whichever tab was already visible.

This feature will add an on-demand `WezTermFocusAdapter` inside Herdr Menubar. After Herdr focuses the selected pane, the adapter will briefly mark that session's foreground attached client through Herdr's public `client.window_title.set` API, locate the exact marked pane with `wezterm cli list --format json`, activate it with `wezterm cli activate-pane --pane-id`, clear the marker, and bring WezTerm forward. The adapter is ordinary in-process Swift code invoked only by a row click. It is not a daemon, background process, poller, login item, or separately installed service.

## Goals

- Clicking an agent row selects the existing WezTerm tab containing the owning Herdr session's attached client.
- Preserve the existing session-qualified `pane.focus` request before switching the outer terminal tab.
- Target the most recently active attached client when one Herdr session has multiple clients.
- Never create or attach a new WezTerm tab when the session has no attached client.
- Keep temporary correlation markers private, unique, bounded in lifetime, and cleaned up on success, failure, or cancellation.
- Preserve the existing generic terminal activation behavior for configured terminals other than WezTerm.
- Keep all focus and refresh effects scoped to the selected row's owning Herdr session.

## Non-goals

- Supporting session-aware tab selection in Ghostty, iTerm2, Terminal, Kitty, or Alacritty.
- Installing a background helper, launch agent, shell hook, or WezTerm configuration fragment.
- Opening a new Herdr client when no existing attached client can be found.
- Selecting among several clients manually; Herdr's foreground-client choice is authoritative.
- Managing WezTerm workspaces or changing the user's WezTerm configuration.
- Guaranteeing focus across separately addressed WezTerm GUI or mux instances. The supported case is existing tabs or panes in the running WezTerm instance selected by `wezterm cli`.
- Changing Herdr's public socket protocol.

## Current behavior and root cause

The existing selection sequence is:

1. `AgentStore` calls `SessionSupervisor.focus(sessionID:paneID:)`.
2. The supervisor routes the command to that session's fixed-socket `HerdrClient`.
3. The client sends `pane.focus` to the correct Herdr server.
4. `TerminalActivationService` calls `NSWorkspace.openApplication` with `activates = true`.
5. The store refreshes only the selected session.

Steps 1–3 correctly focus the pane in Herdr's server-owned session state. Step 4 can only bring the WezTerm application forward. It has no tab or pane identifier, so it cannot switch the outer WezTerm tab. Existing integration coverage proves that `pane.focus` reaches only the owning Herdr server, but it does not control or assert a real WezTerm tab selection.

## Selected approach

### Temporary title handshake

Herdr's public socket API can set or clear the foreground attached client's outer terminal title. WezTerm's CLI can list panes with their current titles and activate a pane by ID. A unique temporary title therefore provides a short-lived correlation channel without shell configuration or persistent state.

For each click, the app generates an opaque marker such as:

```text
herdr-menubar-focus:<UUID>
```

The marker contains no session name, pane ID, socket path, workspace name, or agent detail. It is never persisted or logged publicly.

The selected approach is preferred over:

- **WezTerm user variables:** explicit and robust, but requires shell or WezTerm configuration outside the app.
- **Title/process inference:** zero setup, but ambiguous and vulnerable to user title formatting, process changes, and duplicate labels.
- **Opening a new attached tab:** reliable only by creating another client, which violates the requirement to avoid surprise duplicates.

## Architecture

### Herdr client-window title control

`HerdrClient` will gain fixed-socket request methods for:

```text
client.window_title.set
client.window_title.clear
```

The API models will represent the title-set parameter and the `client_window_title` result, including its `changed` flag and reason. The supported reasons include successful set or clear and `no_foreground_client`.

The `SessionClientServing`, `SessionSupervisor`, and `SessionSupervising` seams will expose session-qualified title control. The supervisor will route these calls through the same owned runtime used for pane focus and refresh. A missing, absent, or disconnected runtime remains a session-unavailable error; `no_foreground_client` is a distinct attached-client result rather than a transport failure.

### `WezTermFocusAdapter`

`WezTermFocusAdapter` is a small in-process component with three injected dependencies:

- session-qualified Herdr client-window title control;
- a WezTerm CLI runner;
- a clock or sleeper for bounded, deterministic polling.

It has one public operation conceptually equivalent to:

```swift
func focusAttachedClient(sessionID: SessionID) async throws
```

The live CLI runner resolves the executable from the installed WezTerm application bundle rather than interpolating a shell command or trusting arbitrary shell text. It invokes the executable directly with argument arrays.

`wezterm cli list --format json` is decoded into the minimal fields required for matching: `pane_id`, `tab_id`, `window_id`, and `title`. The adapter matches the marker by exact string equality and calls:

```text
wezterm cli activate-pane --pane-id <matched pane id>
```

The adapter does not remain resident beyond the Herdr Menubar process and performs no work until a user selects a row.

### Existing terminal activation

The current terminal preference and `TerminalActivationService` remain. When WezTerm is selected, the row action uses the session-aware adapter before generic application activation. The final macOS activation brings WezTerm forward after the CLI has selected the correct pane and containing tab.

For another selected terminal, the app preserves the current generic application activation path. No session-aware behavior is promised for those terminals.

## Selection data flow

For a WezTerm selection:

1. Clear the current transient error.
2. Send `pane.focus` through the selected item's owning `SessionID` and `paneID`.
3. Generate a unique opaque focus marker.
4. Send `client.window_title.set` through the same session runtime.
5. If Herdr reports `no_foreground_client`, stop with the no-attached-tab error.
6. Poll `wezterm cli list --format json` until one pane title exactly equals the marker or the one-second deadline expires.
7. Activate the matched WezTerm pane ID.
8. Clear the client window title through the same session runtime on a best-effort basis.
9. Activate the configured WezTerm application through macOS.
10. Refresh only the owning Herdr session.

The marker-clear operation is attempted on every path after a successful set, including list failure, malformed output, no match, activation failure, task cancellation, or a superseding selection. Once a pane ID has been matched, title clearing may happen before the pane activation because the stable WezTerm pane ID is sufficient for the remaining command.

The existing ordering remains authoritative: a Herdr pane-focus failure prevents any WezTerm operation or session refresh. A WezTerm targeting failure happens after Herdr has focused the server-side pane, so it reports that partial result precisely rather than claiming the entire focus failed.

### Rapid repeated selections

Row selection is asynchronous and main-actor reentrant. The store will use a selection generation or owned task so the latest click wins. A superseded selection must not activate its stale WezTerm pane or overwrite the newer selection's error. It must still attempt to clear any marker it successfully installed. Each marker is unique, so overlapping cleanup cannot match or activate another selection's pane.

## Foreground-client semantics

Herdr decides which attached client is foreground for a session. The title request deliberately uses that existing choice:

- With one attached client, that client's WezTerm pane is targeted.
- With several attached clients, the most recently active foreground client is targeted.
- With no attached client, Herdr reports `no_foreground_client`; Herdr Menubar shows an error and does not create a tab.

The app does not cache a long-lived session-to-WezTerm mapping. A fresh handshake on each click follows the current foreground client and avoids stale pane IDs after tabs close, move, or restart.

## Timing and subprocess behavior

- The lookup deadline is one second from successful marker installation.
- Polling is cancellation-aware and uses a short bounded interval rather than busy waiting.
- Each CLI invocation captures standard output and standard error with bounded memory.
- Nonzero exit, launch failure, invalid UTF-8 or JSON, and schema mismatch become typed adapter errors.
- Arguments are passed directly to `Process`; no shell, command interpolation, or user-controlled executable path is used.
- The app starts no long-lived `wezterm` process. `list` and `activate-pane` exit after each command.

## Error behavior

User-visible errors are concise and preserve session context without exposing socket paths or opaque markers.

- `pane.focus` failure: preserve the existing `Could not focus pane in <session>: <reason>` behavior; do not run the adapter or activate WezTerm.
- No foreground client: `Focused the pane in <session>, but no attached WezTerm tab was found.`
- Lookup timeout: use the same no-attached-tab message because no exact existing tab was observable.
- WezTerm missing or CLI launch failure: `Focused the pane in <session>, but WezTerm could not be controlled.`
- Malformed list output or pane activation failure: report a WezTerm-control error without raw command output.
- Marker clear failure after successful activation: keep the focus success, log the cleanup failure privately, and retry cleanup only through bounded in-process ownership; do not open a tab or affect another session.

Dynamic session names, pane identifiers, marker values, CLI output, executable paths, and underlying errors remain private in unified logging. The user-facing error may include the session display name, consistent with existing focus errors.

## State and persistence

No mapping, marker, WezTerm pane ID, or selection state is written to disk. Herdr remains the source of truth for session and pane focus. WezTerm remains the source of truth for outer tab and pane identity. Herdr Menubar only correlates them during a click.

## Testing

### API and client tests

- Encode exact `client.window_title.set` and `.clear` requests.
- Decode successful `client_window_title` results and `no_foreground_client`.
- Prove title operations use only the selected session's fixed socket.
- Preserve transport invalidation and privacy behavior on request errors.

### Adapter unit tests

- Parse representative `wezterm cli list --format json` output.
- Match only the exact opaque marker.
- Invoke `activate-pane` with the matched pane ID.
- Handle two sessions with duplicate Herdr pane IDs mapped to distinct WezTerm pane IDs.
- Target the Herdr-selected foreground client when several clients exist.
- Poll until delayed title propagation becomes visible.
- Time out after one second without opening or attaching a tab.
- Handle missing executable, nonzero exit, malformed JSON, duplicate marker matches, and failed activation deterministically.
- Attempt marker cleanup after success, every failure after set, cancellation, and supersession.
- Prove no marker, session name, socket path, or CLI output is logged publicly.

Duplicate exact marker matches should be treated as ambiguous rather than selecting arbitrarily. UUID markers make this exceptional, but failing closed prevents an incorrect tab jump.

### Store orchestration tests

- Assert `pane.focus -> marker set -> list/match -> activate-pane -> marker clear -> app activation -> owning-session refresh`.
- Assert another terminal selection retains generic app activation without WezTerm CLI calls.
- Assert a Herdr focus failure prevents all terminal actions.
- Assert a no-attached-client or lookup failure does not refresh or create a tab and shows the session-qualified partial-focus error.
- Assert rapid clicks are latest-wins and stale operations cannot activate or overwrite errors.

### Subprocess integration

Use a temporary fake `wezterm` executable to exercise real subprocess launch, argument passing, JSON capture, exit status, delayed list visibility, and activation recording without controlling the user's live WezTerm. Tests must use short temporary paths, bounded deadlines, deterministic teardown, and no real GUI dependency.

### Manual smoke test

With a default and named Herdr session attached in two existing WezTerm tabs:

- Clicking an agent in each session selects its exact existing WezTerm tab.
- Duplicate Herdr pane IDs across sessions still select the owning session's tab.
- The selected Herdr pane is focused inside that session after the tab switch.
- Two attached clients for one session select the most recently active client.
- Detaching a session's only client yields the no-attached-tab error and creates no tab.
- Rapid alternating clicks finish on the last selected row.
- No temporary marker remains visible after success or failure.

## Acceptance criteria

- Existing two-tab WezTerm use switches to the selected row's owning Herdr session.
- `pane.focus` and refresh remain routed only to the owning Herdr socket.
- No-attached-client behavior is explicit and never spawns a new tab.
- The most recently active attached client wins when a session has several clients.
- The adapter performs no background polling and installs no helper process or configuration.
- All markers and mappings are ephemeral and cleanup is attempted on every terminal path.
- Existing multi-session, reconnect, aggregation, menu, icon, and non-WezTerm terminal tests remain green.
- Full tests, Release build, static analysis, installer smoke, and a real two-tab WezTerm smoke test pass.
