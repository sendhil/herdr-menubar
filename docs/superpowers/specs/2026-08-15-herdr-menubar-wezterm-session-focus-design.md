# Herdr Menubar WezTerm Session Focus Design

**Date:** 2026-08-15

## Summary

Herdr Menubar already routes a selected agent row's `pane.focus` request to the correct Herdr session. It then activates WezTerm through macOS, but generic application activation cannot select the existing WezTerm tab that contains that session's attached Herdr client. With two Herdr sessions attached in two WezTerm tabs, the internal Herdr pane changes while WezTerm remains on whichever tab was already visible.

This feature will add an on-demand `WezTermFocusAdapter` inside Herdr Menubar. After Herdr focuses the selected pane, the adapter will briefly mark that session's foreground attached client through Herdr's public `client.window_title.set` API, locate the exact marked pane with `wezterm cli list --format json`, clear the marker, activate the matched pane with `wezterm cli activate-pane --pane-id`, and bring WezTerm forward. The adapter is ordinary in-process Swift code invoked only by a row click. It is not a daemon, background process, poller, login item, or separately installed service.

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

The live CLI runner resolves the installed WezTerm application bundle with `NSWorkspace`, then uses the documented scripting binary at `Contents/MacOS/wezterm`. It validates that this exact path is a regular executable file. WezTerm's bundle entry point is `wezterm-gui`, but that is not the CLI binary and must never be invoked for this operation. A missing or non-executable sibling CLI produces a typed unavailable error; production does not fall back to `$PATH`, a Homebrew prefix, or user-controlled shell text. The runner invokes the executable directly with argument arrays.

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
7. Clear the client window title through the same session runtime before making the tab visible.
8. Activate the matched WezTerm pane ID.
9. Activate the configured WezTerm application through macOS.
10. Refresh only the owning Herdr session in operation finalization.

The authoritative success order is therefore `marker set -> list/match -> marker clear -> activate-pane -> macOS activation -> refresh`. Clearing before activation prevents the user from seeing the temporary title after the target tab becomes visible. The marker-clear operation is also attempted on every failure path after a successful set, including list failure, malformed output, no match, task cancellation, or supersession. The stable matched WezTerm pane ID remains sufficient after clearing.

The existing first boundary remains authoritative: a Herdr pane-focus failure prevents any WezTerm operation or session refresh. Once `pane.focus` succeeds, the owning session is refreshed exactly once during operation finalization, even when title marking, list parsing, lookup, marker cleanup, `activate-pane`, macOS activation, cancellation, or supersession subsequently fails. This preserves Herdr's seen-state transition and the existing non-WezTerm behavior that refreshes after an application-activation failure. A WezTerm targeting failure reports the partial result precisely rather than claiming the server-side pane focus failed.

### Rapid repeated selections

Row selection is asynchronous and main-actor reentrant. `AgentStore` will own one selection task and a selection generation. A new click invalidates and cancels the old generation, then **awaits the old task's complete finalization, including marker cleanup and any required owning-session refresh, before the new task may set a marker or send its own `pane.focus`**. After that barrier, the new operation revalidates that it is still the latest generation before proceeding.

This serialization is required because `client.window_title.clear` is unconditional: uniqueness alone cannot prevent an old cleanup from clearing a newer marker on the same foreground client. At most one marker handshake is therefore active at a time across the app. The old operation checks cancellation and generation ownership before title matching, `activate-pane`, macOS activation, and user-visible error mutation. It cannot activate or publish an error after it is superseded. If its `pane.focus` already succeeded, it completes its scoped refresh before the successor begins; the successor's later pane focus is the final focus effect. `AgentStore.stop()` invalidates, cancels, and awaits the owned selection task before stopping the supervisor.

## Foreground-client semantics

Herdr decides which attached client is foreground for a session. The title request deliberately uses that existing choice:

- With one attached client, that client's WezTerm pane is targeted.
- With several attached clients, the most recently active foreground client is targeted.
- With no attached client, Herdr reports `no_foreground_client`; Herdr Menubar shows an error and does not create a tab.

The app does not cache a long-lived session-to-WezTerm mapping. A fresh handshake on each click follows the current foreground client and avoids stale pane IDs after tabs close, move, or restart.

## Timing and subprocess behavior

- The lookup deadline is one second from successful marker installation.
- Polling is cancellation-aware, waits 50 milliseconds between unsuccessful observations, and never busy waits.
- Each `wezterm cli list --format json` invocation has a 500-millisecond deadline inside the one-second overall lookup deadline.
- `wezterm cli activate-pane` has a one-second invocation deadline.
- Each CLI invocation drains standard output and standard error concurrently and retains at most 256 KiB from each stream. Exceeding either limit terminates the process with a typed output-too-large error.
- Cancellation or timeout first requests termination, waits at most 100 milliseconds, then sends `SIGKILL` if necessary and always waits for process exit before returning. Pipe readers are also canceled and awaited, so no subprocess or reader task escapes operation ownership.
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
- Marker clear failure before activation: make at most three clear attempts separated by 100 milliseconds and bounded by 500 milliseconds total, report a WezTerm-control error if cleanup still fails, and do not make the marked tab visible. Record the session as pending cleanup in memory. A later selection of that session gets one new bounded cleanup sequence before any new marker may be installed; if it still fails, the new handshake is rejected. No background task or persistence is introduced, and a different session may still be selected after the prior operation finalizes.

Dynamic session names, pane identifiers, marker values, CLI output, executable paths, and underlying errors remain private in unified logging. The user-facing error may include the session display name, consistent with existing focus errors.

## State and persistence

No mapping, marker, WezTerm pane ID, or selection state is written to disk. Herdr remains the source of truth for session and pane focus. WezTerm remains the source of truth for outer tab and pane identity. Herdr Menubar only correlates them during a click.

The feature is verified against Herdr 0.7.3's `client.window_title.set` and `.clear` methods. Compatibility with an older server is not required. If a running server returns `method_not_found`, the app reports that the Herdr session must be updated for WezTerm tab focus; it does not fall back to title inference or tab creation.

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

- Assert `pane.focus -> marker set -> list/match -> marker clear -> activate-pane -> app activation -> owning-session refresh`.
- Assert another terminal selection retains generic app activation without WezTerm CLI calls.
- Assert a Herdr focus failure prevents all terminal actions.
- Assert every successful `pane.focus` refreshes its owning session exactly once after success, no-attached-client, lookup failure, malformed output, marker-cleanup failure, pane-activation failure, macOS-activation failure, cancellation, and supersession; a failed `pane.focus` never refreshes.
- Assert no failure path creates a tab and each shows the appropriate session-qualified partial-focus error only when its generation is current.
- Assert rapid clicks serialize at the cleanup barrier, are latest-wins, and stale operations cannot clear a successor's marker, activate a pane, or overwrite errors after the successor begins.

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
- No temporary marker remains after success and ordinary failure paths where Herdr still accepts the cleanup request. A forced title-clear transport failure reports the cleanup problem and demonstrates bounded retry; the smoke test does not claim that an unreachable client can always be cleaned remotely.

## Acceptance criteria

- Existing two-tab WezTerm use switches to the selected row's owning Herdr session.
- `pane.focus` and refresh remain routed only to the owning Herdr socket.
- No-attached-client behavior is explicit and never spawns a new tab.
- The most recently active attached client wins when a session has several clients.
- The adapter performs no background polling and installs no helper process or configuration.
- All markers and mappings are ephemeral and cleanup is attempted on every terminal path.
- Existing multi-session, reconnect, aggregation, menu, icon, and non-WezTerm terminal tests remain green.
- Full tests, Release build, static analysis, installer smoke, and a real two-tab WezTerm smoke test pass.
