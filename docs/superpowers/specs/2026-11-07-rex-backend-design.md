# Rex Backend and Per-Backend Notifications Design

Revision 6.2 (2026-11-08). See [Revision log](#revision-log).

## Summary

Herdr Menubar will monitor agents running in [Rex](https://www.superlogical.com/rex/docs) alongside agents running in Herdr. Both appear in one menu and feed one badge. Selecting an agent focuses its exact pane. Notifications become configurable per backend and per state.

A backend layer is introduced below `AgentStore`. The existing Herdr supervisor becomes one backend. Rex becomes a second backend driven by the `rex` CLI through one long-running Lua watcher process. **Everything Rex-specific (record reduction, ranking, seen-state, flap protection) lives inside `RexBackend`.** The store, coordinator, and menu see finished rows and attention records from every backend in the same shape. Retiring a terminal later means deleting its backend.

## Goals

- Show Rex panes whose programs report `blocked`, `error`, `done`, or `working` through the Program Status Protocol (OSC 7501).
- Run Herdr and Rex together, separately, or with either absent.
- Herdr-only installs see no change until rollout step 3, which adds a Herdr notification-states submenu (an intentional, listed change).
- Focus the exact Rex pane from a menu row, a notification, or the latest-notification shortcut, preserving latest-selection-wins across backends.
- Let the user choose, per backend, which states notify.
- Make removing a backend a deletion, not a refactor.

## Non-goals

- Talking to the Rex socket directly.
- Remote Rex hosts (`rex hosts`). Local server only.
- Phone push. (`rex.on` handlers in `init.lua` are never called; a separate `rex do` script would be the route.)
- Filtering by Rex blocked `kind`. Carried in the data; not configurable in v1.
- Launching Rex.app when it is not running.
- A UI for `rexCLIPath` or `enabledBackends` (set with `defaults write`).
- Renaming the app.

## Verified facts (Rex server 0.0.1793645657, API revision 10)

Checked live with throwaway sessions or against `--help`, `rex api describe`, and the docs. The newer installed CLI (0.0.1793981048, API 11) also ran the watcher and focus script cleanly against this server.

| # | Fact | Consequence |
|---|------|-------------|
| F1 | `rex do script.lua --all` with `rex.on(...)` hears every session, including later ones. `print` → stdout, streamed. `rex.log` and the `listening:` banner → stderr. A script's `return` value is printed. | One watcher process; the script never returns a value. |
| F2 | A `rex do` stream is attached to no session by default. Session-scoped calls at top level fail with `409 stream is not attached to session`. Inside `rex.after`/`rex.every` timers of an `--all` script they succeed for any session when `session_id` is passed. `rex.block.call` needs `session_id` in its args (else `404 session_not_found`). With `-s S`, a `-e` script's default session is S; `rex.session_id` holds it; **`ctx` is nil in `-e` scripts**. | Snapshot in a timer; pass `session_id` everywhere; one-shot focus uses `-s` and `rex.session_id`. |
| F3 | Failed `rex.*` calls return `nil, err` and do not raise. An error in a timer is printed to stderr and the script continues. `session.list` `sessions` may be null; `view.windows` is omitted for a session with no blocks. | Nil guards; `pcall` around the snapshot. |
| F4 | `terminal.program_status_changed`: `ctx.session_id`, `ctx.block_id`, `ev.id` (`""` for root), `ev.reason`, `ev.record` (`state`, `kind`, `app`, `effective_app`, `title`, `msg` decoded, `updated_at`, `owner`). `program_status` records omit `id` for the root. Child records may have `effective_app` and no `app`. | Normalize root id to `""`; use `effective_app`. |
| F5 | `terminal.program_status_removed`: `ev.ids` lists every removed id. On child exit, `working`/`blocked` are removed; `done`/`error` survive. | Handled by re-read (F7). |
| F6 | `rex.json.encode` encodes any empty table as `{}`, drops nil fields, escapes `<`, `>`, `&` as six-byte sequences, returns `nil, err` for NaN. | Lenient array decoding; clip free text in Lua. |
| F7 | `program_status` calls cost ~0.2 ms. Events queued while a handler or timer runs are delivered afterwards, not lost; events during top-level execution are dropped. Queued events replay after a snapshot. | Each status event triggers a re-read of that block and an authoritative per-block line. |
| F8 | `updated_at` is RFC 3339, trailing zeros trimmed, local offset. Not fixed-width. | Never compared as text. Where ordering is needed it is parsed into integer microseconds since the Unix epoch (offset applied). |
| F9 | `block_closed`: `ev.block_id`. `session_destroyed`: `ev.session_id`. `rex kill` emits `block_closed` per block, then `session_destroyed`. `session_created` fires after windows exist, not followed by `session_view_changed`; session is `ev.session.session_id`. Renaming a block, window, or session emits `session_view_changed` (and `session_label_changed` for sessions). A block whose program exits emits `program_status_removed`, and a re-read in that window can 404 before `block_closed`. | View on create; debounced view on changes; 404 means gone. |
| F10 | `session.view` gives windows → layers → blocks with labels and the session label. An unnamed window is labeled `Window ` + the last 8 hex digits of its window id; terminal blocks default to `shell`. `session.focus_block` requires a placed block; it un-minimizes a minimized floating layer. | Default labels detected exactly; only placed blocks get rows. |
| F11 | Server-side focus and CLI keystrokes never clear `done`. The Rex app hides its own indicator when viewed; the server record stays. | `RexBackend` owns seen-state. |
| F12 | Client actions from the CLI need **Remote Control** (Settings → Rex Server). Refusal: exit 1, stderr `Error: Rex.app is not accepting actions. Turn on Remote Control in its Settings under Rex Server.` `-C` or `-s` naming an unknown target exits 3 (`Error: client target … not found` / `session target … not found`) before any script runs. | Separate server-focus and client-switch calls; exit-code mapping. |
| F13 | `client.list`: `info.kind`, `info.platform`, `info.label` (= ComputerName), `connection_state`, `session_ids`. No displayed-session field. Lost clients linger up to 60 s. | Client selection rule; no auto-seen. |
| F14 | CLI binaries live in `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/<dir>/Rex Server.app/Contents/MacOS/rex`; `<dir>` is `Current` (a real directory) and numbered directories (`1853`, matching Rex.app's `CFBundleVersion`). They can differ in version. The running server here is the `Current` binary. `rex version` prints `rex <ver>-g<sha>`, `commit:`, `built:`, `api: revision N (supports 0 to N)`. `rex --autostart=false server status --json` reports the server's `rex_version` and `api_revision`. GUI apps don't inherit the shell `PATH`. | Prefer the binary whose version equals the server's. |
| F15 | `--autostart` is global. Server unreachable: `do` and `client ls` exit 4 (`Error: no Rex server is running at <path>, and autostart is disabled`); `server status` exits **1** with empty stdout (`Error: rex server is not running`) and ignores `REX_SERVER`/`REX_HOME`. A schema error in `--args` exits 2. `client ls --json` output is `{"clients":[…]}`; some clients have null `info`. SIGTERM: exit 130, `Error: interrupted`. CLI honours `REX_SERVER`, `REX_CLIENT`, `REX_HOME`, `REX_SESSION`, `REX_BLOCK`. `KEY=VALUE` script args are typed (`1e3` becomes a number); `--args` takes JSON. | Exit-code mapping; scrub `REX_*`; pass ids with `--args`. |
| F16 | An orphaned `rex do` (reader gone) runs until its next write, then dies of SIGPIPE. | Heartbeat plus termination on stop. |
| — | Unverified: `rex do` behaviour when the server stops mid-run. | Heartbeat timeout covers it. |

## User experience

### Menu

Sections stay status-first; headings and group headings keep today's styles. Group headings gain a `Backend · ` prefix while more than one backend is [active](#active-backends).

```
NEEDS ATTENTION
  Herdr · Default
    api-server · claude                     blocked · claude
  Rex · fix-playback-completion
    Playback · pi                           blocked · Allow rm -rf build?
FINISHED
  Rex · fix-playback-completion
    Review · claude-code                    done · claude-code
  Clear Finished
WORKING
  Rex · rex-menubar-design
    rex-menubar-design · claude-code        working · claude-code
```

- **NEEDS ATTENTION**: Herdr `blocked`, `done` (unchanged); Rex `blocked`, `error`. Order within a session: `blocked`, `error`, `done`, then label (Herdr's existing `attentionOrder`, extended).
- **FINISHED**: Rex `done`. Shown only when non-empty; ends with **Clear Finished**. Order: label.
- **WORKING**: unchanged for Herdr; Rex `working`. Order: label.
- "No active agents" considers all three sections.
- Herdr rows are unchanged. Rex rows:
  - **Primary label**: the window label unless it is the default (`Window ` + last 8 hex of the window id); else the block label unless it is `shell`; else the session label.
  - **Agent label**: the deciding record's `title`, else `effective_app`, else none.
  - **Secondary**: `<state> · <msg>` if the deciding record has `msg`; else `<state> · <agent label>`; else `<state>`.
  - All Rex text is sanitized (see [Notifications](#notifications)).
- New status symbol for `error`: SF Symbol `xmark.octagon`.
- NSMenu closes when a toggle inside a submenu is clicked. This is accepted for the notification-state toggles.

### Rex rows, ranking, and seen-state (inside RexBackend)

One row per placed Rex terminal block, built by `RexBackend`.

**Records and epochs.** `RexBackend` keeps a table of last-known records keyed by `(session_id, block_id, record id)`. Each record holds its state, its `updated_at` parsed to microseconds (F8), and an **epoch**. The table persists across watcher generations.

- An epoch is a value of one backend-wide counter that only increases. Assigning a new epoch means taking the next counter value, so epochs never repeat, even after a record is dropped and recreated.
- A record gets a new epoch when its observed state differs from its last-known state. That can be observed two ways:
  - **Through an event's `via`** (see the watcher). This applies only when `via.at` is later than the last-known `updated_at`. A stale event replayed after a snapshot carries an older `via.at`, so it is ignored.
  - **Through a re-read.**
- So the epoch advances on every real cycle (`done → working → done`), even when re-reads collapse the intermediate state. It does not advance on an identical re-report.
- **Accepted limitation:** a full cycle that starts and ends while the watcher is down (up to the 60-second backoff) is invisible. The snapshot has no `via`. Such a record keeps its epoch, and a seen mark for it still applies.

**Seen marks.** A seen mark is `(record key, epoch)`. A `done` or `error` record is hidden if and only if a mark with its **current** epoch exists. A new epoch always shows. Marks are pruned when their record disappears or gets a new epoch.

**Ranking.** After hiding seen records, the remaining records decide the row: `blocked` > `working` > `error` > `done` (`working` outranks surviving terminal states so stale `done`/`error` cannot hide live work). `idle` and unknown states are ignored. Ties go to the higher epoch. No remaining records → no row. Blocks that are not yet in a view ("held") produce neither rows nor attention records.

**Marking seen.**
- Every Rex row carries an opaque `seenToken`: the set of `(record key, epoch)` for all `done`/`error` records of the block, before hiding.
- The store captures the token when a selection starts. If the selection completes fully (server focus succeeded, client switch succeeded, still the current selection), the store calls `backend.markSeen(token)`.
- Marks only hide records whose epoch still matches, so a record that changed during focus stays visible.
- A partial focus (Remote Control off, no client) marks nothing.
- **Clear Finished** calls `backend.clearFinished()`, which marks every currently visible `done` record.
- `RexBackend` emits a fresh `.snapshot` for affected sessions after either call.
- Seen marks are in memory and are cleared when the backend stops. After a relaunch, existing Rex `done` records show in FINISHED until seen. They do not notify, because they are part of the startup baseline.

### Badge

Badge = Herdr `blocked` + Herdr `done` (unchanged) + Rex rows in NEEDS ATTENTION (`blocked`, `error`). Rex `done` is never counted: Rex keeps it until replaced or cleared and provides no shared way to clear it, so counting it would make the badge grow without bound. SketchyBar uses the same count.

### Notification settings (rollout step 3)

```
Notifications                 ✓
  Herdr Agents                ▸  Blocked ✓  Finished ✓
  Rex Agents                  ▸  Blocked ✓  Failed ✓  Finished ☐
Sound
```

- **Notifications** stays the main switch and the authorization trigger.
- The Herdr submenu is always shown, when Herdr is enabled. The Rex submenu is shown only when Rex is enabled **and** (Rex has been active in this run, or `notifyStates.rex` is stored). Users without Rex, or with Rex installed but never running, never see it.
- Each item is a toggle. The parent shows a checkmark (all on), a dash (some), or nothing (none). `StatusMenuNode.submenu` gains a `state`.
- **Sound** stays app-wide.
- Defaults: Herdr `blocked`+`done` (today). Rex `blocked`+`error`. Until step 3, the defaults apply with no UI.

### Notifications

- Titles: **Agent blocked**, **Agent failed** (new), **Agent finished**.
- Herdr body: unchanged (`<visible label> — <session>`).
- Rex body: sanitized `msg` on the first line when present; the last line is always `<primary label> — Rex · <session label>`, so the source pane is named as the protocol recommends.
- **Sanitization** applies to all Rex text shown outside the terminal: remove Unicode `Cf` (including bidi controls) and control characters, collapse whitespace, truncate to 200 characters.
- **Rex flap protection** (inside `RexBackend`; Herdr unchanged). Applies to the `attention` list given to the coordinator; menu rows always update immediately.
  - **Settling:**
    - A `(record key, epoch)` in an attention state is **settled** once that epoch has existed for 1.5 seconds.
    - **Immediately settled at a `snapshot_done`**, so a silent baseline always includes them:
      - every record in the first successful `snapshot_done` since the backend started (a failed first attempt doesn't count);
      - every record of a session whose `.connected` from this snapshot is its first to the store, e.g. a session created during an outage.
    - **Not immediately settled:** sessions created live via `session_created`. They start with an empty `.connected`, so their first `blocked` settles and notifies.
    - **After a restart,** a record whose epoch did not change is still settled. A record with a new epoch in a known session must settle, and then notifies once (an outage transition).
    - **Persistence:** settled status is keyed by epoch and persists across generations. `stop()` clears it, together with the epoch counter's history (last-known records); the next `start()` is a fresh "first".
    - **Snapshot on settle:** when a settle timer fires after `snapshot_done`, the backend emits `.snapshot` for that session, if the store knows it.
    - **Late-placed blocks:** a block that was held (not yet in a view) and joins a view later enters `attention` with its existing settled status. This can notify for a block whose status predates its placement. That's accepted, because a block is normally placed within half a second.
    - **Counter after `stop()`:** whether the epoch counter itself resets on `stop()` doesn't matter, because `store.stop()` resets the coordinator at the same time.
    - **Known sessions:** a session leaves "sessions known to the store" when `.removed` is emitted for it.
  - **The attention list** contains exactly the settled attention records. A record leaves the list immediately when its epoch changes or it disappears; its next state must settle on its own.
  - **Effect:** a program that flips `blocked`/`working` faster than 1.5 s produces no notifications, and one that settles produces one.
  - **Timers:** the backend uses an injected clock, and pending settle timers are cancelled on stop.

## Architecture

### Types

```swift
enum BackendKind: String, Codable, Sendable, CaseIterable { case herdr, rex }   // declaration order = sort order

struct AgentSessionKey: Hashable, Sendable {
    let backend: BackendKind
    let rawID: String        // Herdr: "default" or "named:<name>"; Rex: session_id
}

struct AgentSessionDescriptor: Identifiable, Equatable, Sendable {
    let key: AgentSessionKey
    let displayName: String
    var id: AgentSessionKey { key }
}

struct AgentTarget: Hashable, Sendable {
    let session: AgentSessionKey
    let paneID: String       // Herdr: pane_id; Rex: block_id
}

/// Replaces NotificationSelectionTarget everywhere (step 1).
/// Equality and hashing use `target` only; the display name is a message hint, refreshed from
/// the store's current descriptor when one exists.
struct SelectionTarget: Sendable {
    let target: AgentTarget
    let sessionDisplayName: String
}

enum AttentionState: String, Sendable { case blocked, error, done }
enum RowState: Equatable, Sendable {
    case attention(AttentionState)   // NEEDS ATTENTION; counted in the badge
    case finished                    // FINISHED; not counted (Rex done)
    case working                     // WORKING
}

struct AgentRow: Equatable, Sendable {           // final, already seen-filtered and ranked
    let target: AgentTarget
    let displayLabel: String                     // primary label (Herdr: today's displayLabel)
    let agentLabel: String?                      // Herdr: today's agentLabel
    let state: RowState
    let subtitle: String                         // full secondary line, built by the backend
                                                 // (Herdr: today's "status · agentLabel")
    let seenToken: SeenToken?                    // opaque; Rex only
}

struct SeenToken: Hashable, Sendable { let marks: Set<String> }   // opaque to the store

struct AttentionRecord: Equatable, Sendable {    // coordinator input, never seen-filtered
    let target: AgentTarget
    let recordID: String     // Herdr: ""; Rex: record id
    let epoch: Int           // Herdr: 0; Rex: record epoch
    let state: AttentionState
    let visibleLabel: String
    let message: String?     // sanitized; Rex only
}

struct BackendSnapshot: Equatable, Sendable {
    let rows: [AgentRow]
    let attention: [AttentionRecord]             // in delivery order (Herdr: labelOrder)
}

enum BackendEvent: Equatable, Sendable {
    case discovery([AgentSessionDescriptor])     // complete session set
    case connected(AgentSessionDescriptor, BackendSnapshot)
    case snapshot(AgentSessionKey, BackendSnapshot)
    case descriptorChanged(AgentSessionDescriptor)
    case sessionUnavailable(AgentSessionKey, String)
    case removed(AgentSessionKey)
    case backendUnavailable(String)              // whole backend down; history kept
    case backendHidden                           // not installed or disabled
}

/// The message is final, user-facing text. Herdr's "Could not focus pane in X: …" wording moves into HerdrBackend.
enum FocusError: LocalizedError, Equatable {
    case unavailable(String)   // backend unreachable: store also calls retryUnavailable() on that backend.
                               // Rex only; HerdrBackend throws only .failed, so step 1 adds no retries.
    case failed(String)        // target-specific failure: message only
    var errorDescription: String? { switch self { case .unavailable(let m), .failed(let m): m } }
}

protocol AgentBackend: Sendable {
    var kind: BackendKind { get }
    func events() async -> AsyncStream<BackendEvent>
    func start() async                           // returns promptly; work happens in tasks
    func stop() async
    func retryUnavailable() async
    func focusServer(_ target: AgentTarget) async throws      // cancellable
    func activate(_ target: AgentTarget) async -> String?     // nil = success, else partial message
    func refreshAfterSelection(_ target: AgentTarget) async   // after a completed focusServer
    func markSeen(_ token: SeenToken) async
    func clearFinished() async
    func compareSessions(_ a: AgentSessionDescriptor, _ b: AgentSessionDescriptor) -> Bool
}
```

- Herdr's `AgentStatus` decoding is unchanged. `HerdrBackend` maps `blocked`/`done` to attention, `working` to working, everything else to hidden. `markSeen`/`clearFinished` are no-ops.
- `AgentSessionKey.rawID` encodes `.default` as `"default"` and `.named(n)` as `"named:" + n`.
- Session order: `BackendKind` order, then `compareSessions`. Herdr: the current comparator verbatim. Rex: case-folded label, then session id.

### Active backends

A backend is **active** once it has emitted `.discovery` in this run (Rex: after its first `snapshot_done`, even with zero sessions). Herdr is treated as active for wording purposes whenever it is enabled. "Active" drives:
- the `Backend · ` heading prefix (more than one active backend);
- the RECONNECTING line for a backend outage (only for a backend that has been active);
- `connectionState` (computed over active backends, plus Herdr if enabled, so a Herdr user with Rex installed but not running sees exactly today's states);
- strings (below).

### AgentStore changes

**Selection (latest wins).**

0. Capture the `seenToken` of the store's current row for the target, from the store's own row cache, for every selection source (menu, notification, shortcut). The cache may be newer than the row the user saw, so a just-arrived epoch can be marked seen. That is accepted: the user is focusing that exact pane, and any record that changes during focus gets a new epoch and shows again.
1. `try await backend.focusServer(target)`. On error, if still current, set `transientError` to the error's `localizedDescription` (each backend produces final wording; Herdr's is today's text). Return without refresh (as today).
2. `guard ownsSelection(generation)` else `refreshAfterSelection` and return. This preserves `testSupersededSuccessfulSelectionCannotActivateAndStillRefreshes`.
3. `let partial = await backend.activate(target)`. If still current and `partial != nil`, set `transientError`.
4. If still current and `partial == nil` and a token was captured: `await backend.markSeen(token)`.
5. `await backend.refreshAfterSelection(target)`.

A superseding selection cancels the previous task. `RexBackend` runs child processes through `ManagedProcess`, which terminates the child on cancellation; `activate` checks `Task.isCancelled` before activating Rex.app.

**Pending notification target.** The store owns one pending target, as today.

- **Herdr targets:** today's rules, with no deadline. A target is held until discovery, held through the supervisor's grace period, and discarded when its session is absent or removed.
- **Rex targets:**
  - **Deadline:** the store starts a deadline task with an injected clock when the target is received. It is cancelled when the target is superseded, resolved, or discarded, or when the store stops.
  - **Resolved** by `.connected` for its session, or immediately if that session is already connected.
  - **Discarded** with an error in any of these cases. Each condition is checked when the target arrives and again on each relevant event.

    | Condition | Message |
    |---|---|
    | (a) Rex has emitted `.discovery` and the session is absent | "<session> is no longer running in Rex" |
    | (b) `.removed` for the session | "<session> is no longer running in Rex" |
    | (c) the backend is currently hidden | "Rex is not available" |
    | (d) 30 seconds after receipt without resolution | "Rex did not respond in time" |
- **Disabled backend:** a target for a backend missing from `enabledBackends` is discarded immediately with "Rex is turned off" (or "Herdr is turned off").

**Unavailability.**

- `.sessionUnavailable`: today's per-session behaviour.
- `.backendUnavailable(reason)`: for each of that backend's sessions, clear rows and badge contribution, call the coordinator's existing `unavailable` (history kept), and mark the session not connected. These sessions are excluded from `unavailableSessions` and from `connectionState`. If the backend has been active, RECONNECTING shows one line, **Rex**, in the same style as existing session lines; the reason goes to the tooltip and the log.
- `.backendHidden`: remove the backend's sessions and their coordinator history; show nothing. (A backend that had resolved its CLI earlier in the run and then cannot find it emits `.backendUnavailable`, not `.backendHidden`, so a Rex update does not drop history.)
- **Retry Unavailable Sessions** is shown when any session or backend line is shown. It calls `retryUnavailable()` on every enabled backend concurrently.

**Descriptors.** `.descriptorChanged` updates the display name for headings and future notifications. It does not touch the coordinator.

### Notification coordinator changes

- `reconcile(session: AgentSessionDescriptor, records: [AttentionRecord], policy:)`. History is keyed by `(AgentTarget, recordID)` and stores `(state, epoch)`.
- **Each reconcile replaces the session's history** with exactly the given records, as today (`statuses[session] = current`). A record absent from a reconcile is dropped from history, and its reappearance is absent → present.
- A delivery candidate is a record whose `(state, epoch)` differs from history, including absent → present.
- Herdr records always have `recordID ""` and `epoch 0`. Duplicate pane IDs are handled the way today's coordinator handles them: `HerdrBackend` dedupes panes last-wins **first**, then keeps only attention states. Herdr's rule is therefore exactly today's per-pane rule, with `working`/`idle`/`unknown` counting as absent. The coordinator delivers at most once per key per reconcile.
- **A resurfacing stale error never re-notifies:** a record that stays present across reconciles keeps its `(state, epoch)`, even when another record (e.g. `working`) outranks it in the menu row.
- **A record that is dropped and recreated always re-notifies,** because epochs never repeat.
- `NotificationDeliveryPolicy` gains `notifyStates: [BackendKind: Set<AttentionState>]`.
- Candidates are delivered in the order given (`BackendSnapshot.attention` order). For Herdr that is today's `labelOrder`, so the latest-notification target is unchanged.
- Delivery condition: `notificationsEnabled && notifyStates(backend).contains(state)`. Unchecked states still update history.
- `unavailable(session)`, `remove(session)`, and `reset()` keep today's semantics, keyed by `AgentSessionKey`.
- Notifications that are not delivered never become the latest-notification target.
- **Baselines.**
  - A session's first `.connected` is a silent baseline (unchanged).
  - A Rex session created while the watcher runs gets `.connected` with an empty snapshot first, so its first `blocked` notifies.
  - **Watcher restart:** `.backendUnavailable`, new generation, then `.connected` for every session after `snapshot_done`. Epochs persist in `RexBackend`, so unchanged records compare equal to history and changed ones notify once. Sessions created during the outage get a silent baseline (their records are settled immediately, see flap protection). Sessions absent from the new snapshot get `.removed`.

### Notification payload

- Version 2 keys: `version`, `backend`, `session_display_name`, `pane_id`, plus for Herdr the existing `session_kind`/`session_name`, and for Rex `rex_session_id`.
- `isSupportedPayloadVersion` accepts 1 and 2. Version 1 decodes through the existing Herdr path. Version 2 dispatches on `backend` and produces a `SelectionTarget`.

### Preferences

| Key | Type | Absent means | Written when |
|---|---|---|---|
| `notificationsEnabled`, `notificationSoundEnabled` | Bool | unchanged | unchanged |
| `notifyStates.herdr` | [String] | `["blocked","done"]` | user changes it |
| `notifyStates.rex` | [String] | `["blocked","error"]` | user changes it |
| `enabledBackends` | [String] | `["herdr"]` until step 3, then `["herdr","rex"]` | `defaults write` only |
| `rexCLIPath` | String | resolve automatically | `defaults write` only |

`NotificationSettingsController` gains `notifyStates(for:)` and `setNotifyState(_:enabled:for:)`. A backend missing from `enabledBackends` emits `.backendHidden` at start and never spawns anything.

### Rex backend

#### CLI resolution (in a background task, at start, on each watcher restart, and on retry)

1. `rexCLIPath`, if set.
2. Candidates: `…/RexServer/Versions/*/Rex Server.app/Contents/MacOS/rex`, then `/opt/homebrew/bin/rex`, `/usr/local/bin/rex`, `~/.local/bin/rex`. If none exist and Rex.app is installed (`NSWorkspace.urlForApplication(withBundleIdentifier: "com.superlogical.rex")` is non-nil), also `$SHELL -lc 'command -v rex'` (3-second timeout, once per launch). The shell probe never runs for users without Rex.app.
3. Validate each candidate with `rex version` (2-second timeout): parse `rex <version>` (up to the first space) and `api: revision <N>`; require N ≥ 10.
4. Run `rex --autostart=false server status --json` with the first valid candidate (3-second timeout).
   - **Server unreachable:** any non-zero exit, or stdout that is not a JSON object with `rex_version`. Prefer `Current`, else the first valid candidate, and treat the server as unreachable (60-second retry interval). `server status` exits 1, not 4, in this case (F15).
   - **Otherwise:** pick the candidate whose version equals `rex_version`. If none matches, prefer `Current`, then the highest API revision.
5. If the chosen binary's watcher exits on its own before `snapshot_done`, with an exit code other than 4, it is remembered as failed for this run. Timeouts and our own termination don't count. Resolution skips failed candidates until none are left, then clears the list.

Nothing found and never found in this run → `.backendHidden`, rechecked every 5 minutes. Previously found → `.backendUnavailable`.

#### ManagedProcess

A new type (the earlier `BoundedProcessRunner` was removed in 478c560):

- `Process` with argv only; environment = the app's minus every `REX_*` variable.
- Stdout through `JSONLineFramer` with a new opt-in `maxLineLength`. Herdr's use is unchanged. The watcher uses 4 MiB.
- Stderr drained continuously into a 16 KiB ring buffer.
- `terminate()`: SIGTERM, wait up to 1 second, then SIGKILL. Called on task cancellation, on `RexBackend.stop()` (reached through the existing `applicationShouldTerminate` → `runtime.stop` → `store.stop` path), and on watcher failure.
- Lines are tagged with the process generation; older generations are discarded.
- One-shot runs take a timeout (version 2 s, server status 3 s, focus 5 s).

#### Watcher script

Bundled as `RexWatcher.lua`; run as `rex --autostart=false do <path> --all`. It emits one JSON object per line.

```lua
local TERMINAL = "com.superlogical.terminal"
local TEXT_MAX = 300

local function out(t)
  local s, err = rex.json.encode(t)
  if not s then s = rex.json.encode({ t = "encode_error", err = tostring(err) }) end
  print(s); io.stdout:flush()
end

local function clip(s)
  if type(s) ~= "string" or #s <= TEXT_MAX then return s end
  local cut = TEXT_MAX
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  return s:sub(1, cut)
end

local function gone(err)
  local e = tostring(err)
  return e:find("code=not_found", 1, true) or e:find("code=session_not_found", 1, true)
end

-- Authoritative re-read of one block. `via` carries what the triggering event said.
local function block_status(s, b, via)
  local st, err = rex.block.call(TERMINAL, "program_status", { session_id = s, block_id = b })
  if not st then
    if gone(err) then out{ t = "block", s = s, b = b, records = {}, gone = true, via = via }
    else out{ t = "status_error", s = s, b = b, err = tostring(err) } end
    return
  end
  local recs = {}
  for _, r in ipairs(st.records or {}) do
    recs[#recs + 1] = { id = r.id or "", state = r.state, kind = r.kind, at = r.updated_at,
                        app = r.effective_app or r.app, title = r.title, msg = clip(r.msg) }  -- title ≤192 bytes by protocol
  end
  out{ t = "block", s = s, b = b, records = recs, via = via }
end

local function view(s)
  local v, err = rex.session.view{ session_id = s }
  if not v then
    if not gone(err) then out{ t = "view_error", s = s, err = tostring(err) } end
    return
  end
  local blocks = {}
  for _, w in ipairs(v.windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      for _, bl in ipairs(l.blocks or {}) do
        blocks[#blocks + 1] = { b = bl.block_id, creator = bl.creator_name,
                                window_id = w.window_id, window_label = w.label, block_label = bl.label }
      end
    end
  end
  out{ t = "view", s = s, session_label = v.label, blocks = blocks }
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  local r = ev.record or {}
  block_status(ctx.session_id, ctx.block_id, { id = ev.id or "", state = r.state, at = r.updated_at })
end)
rex.on("terminal.program_status_removed", function(ctx, ev)
  block_status(ctx.session_id, ctx.block_id, { removed = ev.ids })
end)
rex.on("block_closed",      function(ctx, ev) out{ t = "block_closed", s = ctx.session_id, b = ev.block_id } end)
rex.on("session_destroyed", function(ctx, ev) out{ t = "session_destroyed", s = ev.session_id } end)
rex.on("session_created",   function(ctx, ev)
  local s = ev.session and ev.session.session_id
  if not s then return end
  out{ t = "session_created", s = s, label = ev.session.label }
  view(s)
end)

local pending = {}
local function schedule_view(s)
  if not s or pending[s] then return end
  pending[s] = rex.after(0.5, function() pending[s] = nil; view(s) end)
end
rex.on("session_view_changed",  function(ctx) schedule_view(ctx.session_id) end)
rex.on("session_label_changed", function(ctx) schedule_view(ctx.session_id) end)
rex.on("block_created",         function(ctx) schedule_view(ctx.session_id) end)

local function snapshot()
  local listed, err = rex.call("session.list")
  if not listed then error("session.list: " .. tostring(err)) end
  for _, s in ipairs(listed.sessions or {}) do
    local id = s.session_id
    local lb, e2 = rex.session.list_blocks{ session_id = id }
    if lb then
      out{ t = "session", s = id, label = s.label }
      view(id)
      for _, b in ipairs(lb.blocks or {}) do
        if b.creator_name == TERMINAL then block_status(id, b.block_id, nil) end
      end
    elseif not gone(e2) then
      error("list_blocks " .. id .. ": " .. tostring(e2))
    end
  end
  out{ t = "snapshot_done" }
end

rex.after(0, function()
  local ok, err = pcall(snapshot)
  if not ok then out{ t = "snapshot_error", err = tostring(err) }; rex.stop(1) end
end)
rex.every(5, function() out{ t = "heartbeat" } end)
-- no return value (F1)
```

Fixtures are recorded from this script against the live server during implementation.

#### Reducer (pure, inside RexBackend)

The reducer's per-generation state is reset at the start of each watcher generation: sessions, views, and current records per block. The backend-level state persists across generations: last-known records with epochs, the epoch counter, seen marks, settled status, the set of sessions known to the store, and settle timers.

- Array fields decode leniently: an empty JSON object equals `[]`.
- `session` (snapshot): record the session and its label.
- `view`: replace the session's view and update its label. After `snapshot_done`, a changed label emits `.descriptorChanged`. Lines for unknown sessions are ignored.
- `block`:
  1. **`via` check.** Apply this step if `via.state` and `via.at` are present, a last-known record exists for `via.id`, `via.at` (parsed) is later than its last-known `updated_at`, and `via.state` differs from its last-known state.
     - Assign a new epoch.
     - Update the last-known state and time to `via`'s.
  2. **Re-read.** Replace the block's current records. For each record, compare with last-known: a missing entry or a different state gets a new epoch. Then store the record's state and parsed `at` as last-known.
  3. **Drop.** Records absent from the read are dropped from last-known, along with their seen marks and settled status.
  - `gone: true` is treated as an empty read.
  - A block not yet in its session's view is held. It gets a row once a `view` includes it.
- `block_closed`: drop the block's records, last-known entries, seen marks, and settled status.
- `session_destroyed`: drop everything for the session; emit `.removed`.
- `session_created` (after `snapshot_done`):
  - Unknown session: create it and emit `.connected(descriptor, empty)`.
  - Known session: treat as a label update only.
- `snapshot_done`:
  1. Prune last-known records, seen marks, and settled status for blocks and sessions absent from this generation's snapshot.
  2. Emit `.discovery`.
  3. Emit `.connected` per session with its current rows and attention.
  4. Emit `.removed` for sessions known to the store and absent now.
- After `snapshot_done`, any line that changes a session's rows or attention emits `.snapshot` for that session. Emissions may be coalesced per session within one run-loop turn, but a `.connected` is never merged with a following `.snapshot`.
- Errors:
  - `status_error` or `view_error` before `snapshot_done`: watcher failure.
  - After `snapshot_done`: logged, and the previous records or view are kept.
  - `snapshot_error`, `encode_error`, or an oversized line: watcher failure.

#### Lifecycle and failure

- `start()` returns immediately; resolution and spawning run in a task.
- After spawning, `snapshot_done` must arrive within 20 seconds. After `snapshot_done`, a heartbeat must arrive at least every 15 seconds. Heartbeat supervision starts at `snapshot_done`, because a long snapshot delays timers.
- Failure means any of: process exit, `snapshot_error`, snapshot timeout, heartbeat timeout, or a framing error. On failure:
  - terminate the process;
  - emit `.backendUnavailable(reason)`;
  - restart with backoff 1 s, 2 s, 5 s, 15 s, then every 60 s.
- A watcher exit of 4, or an unreachable result from `server status` during resolution, jumps straight to the 60-second interval.

#### Focus

**Client selection.** Run `rex --autostart=false client ls --json` fresh for each focus. Keep clients with `info.kind == "app"`, `info.platform == "macos"`, and a `connection_state` other than `"lost"` (a missing or unknown value counts as connected, per `rex api describe client.list`). Prefer the one whose `info.label` equals `Host.current().localizedName`. Otherwise use the only remaining client if exactly one is left. Otherwise there is no client.

**`focusServer(target)`:**

```
rex --autostart=false do -s <session_id> --args '{"block":"<block_id>"}' -e '<script>'
```

The script is:

```lua
local r, err = rex.session.focus_block{ block_id = rex.args.block }
print(rex.json.encode(r and { focus = "ok" } or { focus = "error", err = tostring(err) }))
```

Ids are passed only through `--args` JSON. The session defaults from `-s` (`rex.session_id`); `ctx` is not used.

| Result | Mapping |
|---|---|
| exit 0, `focus:"ok"` | success |
| exit 0, `focus:"error"` with `code=not_found` | `FocusError.failed("That pane no longer exists in <session label>")` |
| exit 0, `focus:"error"` otherwise | `FocusError.failed("<session label>: <err>")` |
| exit 3 | `FocusError.failed("<session label> is no longer running in Rex")` |
| exit 4 | `FocusError.unavailable("Rex is not running")` |
| any other exit, or no JSON line | `FocusError.failed` with the last stderr line |

There is no fallback.

**`activate(target)`:**

1. No client selected:
   - If Rex.app is running, activate it and return "Rex app is not connected to the server."
   - Otherwise return "Rex is not running."
2. Run `rex --autostart=false -C <client_id> do session.select --args '{"session_id":"<session_id>"}'`.

   | Result | Outcome |
   |---|---|
   | exit 0 | continue |
   | exit 1 with `not accepting actions` | partial: "Turn on Remote Control in Rex Settings → Rex Server to switch sessions." |
   | exit 3 | partial: "Rex app disconnected." |
   | other | partial with the last stderr line |
3. If not cancelled, activate Rex.app with `NSWorkspace` (bundle identifier `com.superlogical.rex`). No Apple Events are needed.
4. Return the partial message, or nil.

Server focus runs before the client switch, matching the user's `jump_attention` action.

**`refreshAfterSelection`**: no-op for Rex.

### Herdr backend

`HerdrBackend` wraps `SessionSupervisor` and is `@MainActor`, like `AgentStore`, so Ghostty calls need no extra hop. Its focus and Ghostty messages take the session name from the raw ID (`SessionID.displayName` decoded from `rawID`), which is exactly today's text, since Herdr descriptors carry no other name. `RexBackend` does the same from its reducer, falling back to "Rex session".
- `focusServer` is `supervisor.focus`.
- `activate` runs the Ghostty exact-surface focus or terminal activation, with today's partial-focus wording.
- `refreshAfterSelection` is `supervisor.refresh`.
- On forwarding a supervisor `.removed`, it calls Ghostty `forget(sessionID:)`.
- Row construction moves from `AgentMenuItem.init` into the backend unchanged. Attention records come in today's `labelOrder`.
- Supervisor events map one-to-one onto `BackendEvent`.
- When Herdr is missing from `enabledBackends`, `HerdrBackend` emits `.backendHidden` and does not start the supervisor.

### Strings and icon

User-visible "Herdr" strings:
- `StatusItemController` status button: accessibility label `"Herdr"`, tooltip `"Herdr — …"`, `"Herdr terminal status"`;
- `MenuBarIcon` accessibility label and `accessibilityValue`;
- `StatusMenuPresentation` connection strings ("Searching for Herdr sessions…", "No Herdr sessions running", …);
- the SketchyBar summary.

They take a new `wording` input (`.herdr` or `.agents`) computed by `AgentStore`: `.agents` when Rex is active, else `.herdr`. `MenuBarIconPresentation.init` and `accessibilityValue` gain this parameter.

The icon dims only when no session of any active backend is connected.

### Menu actions and runtime wiring

- `StatusMenuAction` gains `.clearFinished` and `.setNotifyState(BackendKind, AttentionState, Bool)`.
- `.select` takes a `SelectionTarget`.
- `ApplicationRuntimeDependencies` gains the matching closures, and `ApplicationRuntime.perform` handles them.
- The type change from `NotificationSelectionTarget` to `SelectionTarget` touches:
  - `NotificationModels` (broker, `LatestNotificationTargetRecording`)
  - `LatestNotificationTargetStore`
  - `NativeNotificationService` (payload)
  - `GlobalShortcutController`
  - `ApplicationRuntime` (dependencies, `receiveFocusLatestShortcut`, relay)
  - `StatusMenuPresentation` (`.agent`, `.select`)
  - `AgentStore`

### Implementation decisions

- **Sections and badge** come from `RowState` only. `.attention` goes to NEEDS ATTENTION and counts toward the badge, `.finished` goes to FINISHED, and `.working` goes to WORKING. The store never branches on backend for presentation.
- **`connectionState` aggregation**, over enabled backends that are active (plus Herdr when enabled), first match wins:

  | Condition | State |
  |---|---|
  | Any connected session | `.connected` |
  | Any connecting session (a known session that is not connected, including an unavailable Herdr session, as in today's `deriveConnectionState`) | `.connecting` |
  | Rex active and currently unavailable (watcher restarting) | `.connecting` |
  | Rex active with zero sessions | `.noSessions` |
  | Herdr enabled | Herdr's own state (`.searching`/`.noSessions`) |
  | Otherwise | `.searching` |

  The two Rex rows only apply once Rex is active, so a Herdr-only user always reaches the Herdr row exactly as today. Implementation computes each backend's own state first (Herdr: today's `deriveConnectionState` verbatim) and then aggregates with this table.
- **`.agents` wording:**

  | Herdr wording | `.agents` wording |
  |---|---|
  | "Searching for Herdr sessions…" | "Searching for agent sessions…" |
  | "No Herdr sessions running" | "No agent sessions running" |
  | accessibility label "Herdr" | "Agents" |
  | tooltip prefix "Herdr — " | "Agents — " |
  | "Herdr terminal status" | "Agent status" |

  Other connection strings follow the same substitution.
- **Isolation:**
  - `HerdrBackend` is `@MainActor`.
  - `RexBackend` is an `actor` whose reducer is a pure struct it owns.
  - `kind` and `compareSessions` are `nonisolated` on both.
- **Event streams:** the store subscribes with `events()` **before** calling `start()` (preserving `testStoreSubscribesToSupervisorEventsBeforeStartingIt`); `stop()` finishes the stream. The store runs one consuming task per backend and applies events on the main actor in arrival order per backend. Coalescing in `RexBackend` happens per session within one batch of processed lines.
- **`retryUnavailable()`** returns promptly in every state and honours cancellation:
  - healthy: no-op
  - in backoff: restart now and reset the backoff
  - hidden: re-run CLI resolution in the background
- **Child processes:** `client ls`, `version`, `server status`, and the shell probe all run through `ManagedProcess` with timeouts. They are terminated on cancellation and on stop. The shell probe runs in its own process group, which is killed as a group.
- **Clock:** `AgentStore` and `RexBackend` take an injected clock for deadlines, settling, and heartbeats.
- **Stop:** `RexBackend.stop()` resets the set of sessions known to the store.
- **Payload rollback:** step 1 writes payload v2 for Herdr. Rolling back to a pre-step-1 build makes clicks on notifications still in Notification Center no-ops. This is accepted.
- **Ghostty `forget`:** `HerdrBackend` calls `forget` only for sessions it had forwarded as known, which preserves today's guard.

## Testing

- **Step 1 gate (no behaviour change):** Herdr behaviours re-expressed against `AgentStore` + `HerdrBackend`:
  - supersession (a current selection activates; a superseded one cannot, and still refreshes)
  - exact-session focus with no fallback, and the Ghostty partial-focus messages
  - pending-target grace hold
  - notification baseline, transitions, label-ordered delivery, and the latest-notification target
  - session order, Ghostty forget on removal, and retry
  - `named:default` vs default
  - payload v1 round trip

  About 21 store tests move to `HerdrBackend` and are rewritten. About 550 references to moved types across 15 test files change.
- **Reducer and RexBackend** (fixtures recorded from the final script):
  - `{}` arrays
  - re-read replaces records; replay after the snapshot is idempotent
  - `via` advances epochs across a collapsed `done → working → done`, and an identical re-report doesn't
  - `blocked` is removed on exit while `done` survives; a `gone` read
  - `block_closed`; `session_destroyed` after `block_closed`
  - a new session gets a view and rows; a known-session `session_created` is a label-only update
  - renames update the descriptor
  - unknown-session lines are ignored
  - default-label detection by window id
  - ranking, with `working` over stale terminal states
  - seen marks hide only the current epoch, prune on change, and Clear Finished works
  - flap protection with an injected clock
  - per-generation reset, with epochs persisting across restart
  - errors before vs after the snapshot
- **Watcher integration test:** runs the bundled script against a live server with `--for`, creating and killing a throwaway session. Skipped when no valid CLI resolves.
- **Coordinator:**
  - per-record `(state, epoch)` transitions; a resurfacing stale error doesn't notify; a new cycle notifies
  - per-backend state filter with no replay
  - Herdr exactly as today
  - a new session's first `blocked` notifies
  - restart reconciliation, and silent baselines for sessions created during the outage
- **Selection:**
  - cross-backend supersession: Rex then Herdr within 5 s terminates the Rex child and doesn't activate Rex.app
  - the `focusServer` exit-code table
  - `activate` outcomes
  - mark-seen only after full success
- **Discovery and visibility:**
  - Herdr-only with Rex absent, disabled, or installed but never running produces today's menu model and strings exactly, in steps 1 and 2, and in step 3 apart from the Herdr notification submenu
  - Rex pending-target rules, including the 30-second deadline and cancellation
- **CLI resolution:** version matching against `server status`, the shell probe gated on Rex.app, validation parsing, and the `.backendHidden` vs `.backendUnavailable` distinction.
- **ManagedProcess:** env scrub, opt-in line cap, stderr ring, terminate on cancel, generation tags.
- **Payload:** v1 and v2 decode.
- **Live check (manual, Remote Control on, `enabledBackends` including `rex`):**
  - Use a throwaway session that reports each state with `printf '\e]7501;state=…\e\\'`. `rex new` attaches the Rex app to it.
  - Confirm rows, FINISHED, the badge, notifications, focus from a notification, and cleanup on kill.

## Rollout

1. **Backend layer, Herdr only.** `AgentBackend`, `HerdrBackend`, `SelectionTarget`, keyed store and coordinator, and payload v2 decode (Herdr encodes v2). The gate is the step-1 tests plus the updated suite. No user-visible change.
2. **Rex backend, complete, off by default.**
   - `ManagedProcess`, CLI resolution, watcher, reducer, ranking, seen-state, FINISHED, Clear Finished, two-step focus, sanitization, flap protection, Rex notifications with default states, strings, and the badge.
   - Enabled with `defaults write <bundle id> enabledBackends -array herdr rex`. Users who don't opt in see no change.
3. **Settings and default-on.** Per-backend notification-state submenus (including the Herdr one), and `enabledBackends` default becomes both.
4. **Later.** Drop the unused backend and rename the app.

## Open questions

- Persist Rex seen-state across relaunches? Deferred.
- Show `progress` on Rex rows? Deferred.
- Upstream requests to Rex:
  - report each client's displayed session in `client.list`
  - clear `done`/`error` on the server when a client views the pane
  - a stable path or symlink for the CLI that matches the running server

## Revision log

- **r6.2 (2026-11-08).** Client selection keeps clients whose `connection_state` is not `"lost"`; a missing or unknown value counts as connected, as documented by `rex api describe client.list`.
- **r6.1 (2026-11-07).** From the r6 confirmation review. The `connectionState` rows were reordered so the Rex rows can be reached. Clarifications:
  - settle snapshots
  - late-placed blocks
  - known-session removal
  - failed-candidate definition
  - Herdr only throws `.failed`
  - descriptor fallback names
  - `block_closed` drops settled status
- **r6 (2026-11-07).** From review round 5.
  - **Settling now matches the baselines:**
    - the first *successful* snapshot settles immediately
    - outage-created sessions settle immediately
    - live-created sessions do not
    - outage transitions in known sessions notify once
    - a settle timer emits `.snapshot`
    - `stop()` resets settling and epochs
  - **Herdr:** dedupe-then-filter order stated; descriptor maps for focus messages.
  - **Smaller fixes:**
    - Rex submenu condition
    - remembering failed CLI candidates
    - `FocusError` cases given distinct behaviour
    - `connectionState` during a Rex restart
    - test statement corrected
    - step-0 rationale corrected
- **r5 (2026-11-07).** From review round 4.
  - **Flap protection:** settled status is keyed by epoch and persists, and the first snapshot counts as settled, so there are no spurious notifications at launch or restart.
  - **Coordinator:** replaces history per reconcile, preserving Herdr exactly.
  - **Epochs:** drawn from one backend-wide counter, so they never repeat; stale `via` events are ignored by parsed time.
  - **Rex submenu:** shown only once Rex is resolved.
  - **CLI resolution:** handles `server status` exiting 1 when the server is down.
  - **Rows and focus:**
    - `RowState.finished` and a backend-built subtitle
    - token captured from the store's cache
    - `LocalizedError` focus messages, plus a `not_found` mapping
  - **Pending targets:** the deadline is Rex-only, with every message assigned and state checked on arrival.
  - **Implementation decisions:** `connectionState` aggregation, `.agents` strings, isolation, streams, retry, clocks, pruning at `snapshot_done`, rollback, `forget` guard.
- **r4 (2026-11-07).** From review round 3.
  - **Moved into `RexBackend`:** seen-state, ranking and flap protection, so the store gets final rows and opaque seen tokens.
  - **Per-record epochs:** using event `via` state fixes cycles hidden by collapsed re-reads, and the epochs survive restarts.
  - **Seen marks:** compared by epoch, so a stale mark can't hide new work.
  - **Coordinator:** gets labels and delivery order; Herdr order is unchanged.
  - **Pending targets:** a store-owned deadline per target.
  - **"Active backend":** now defined.
  - **Watcher fixes:**
    - known-session `session_created` is a label-only update
    - session label taken from `view`
    - 404 treated as gone in Lua, so a mid-snapshot close isn't a failure
    - `ctx` replaced by `rex.session_id`, with ids passed through `--args`
    - full exit-code table
  - **CLI:** chosen by matching the `server status` version; the shell probe is gated on Rex.app; previously found then missing means unavailable, not hidden.
  - **Startup:** `start()` returns promptly; heartbeat supervision starts at `snapshot_done`.
  - **Code fit:** `SelectionTarget` migration list, menu actions, complete string inventory, row order, `enabledBackends` covers both backends, and Rex ships complete and opt-in in step 2.
- **r3 (2026-11-07).** From review round 2: session-attached focus, `session_id` in calls, `pcall` snapshot, lenient arrays, Lua clipping, per-block re-read, views on create, CLI candidates, two-step focus, Herdr `named:` keys, per-backend discovery, backend-level RECONNECTING, per-record coordinator input, rate limiting, preferences, payload v2, strings, test budget.
- **r2 (2026-11-07).** From review round 1: CLI resolution, timer snapshot, exact-id removal, event field sources, label events, detached blocks, Remote Control, client selection, Herdr-only visibility, `connected` event, baselines, Rex done excluded from badge, sanitization, process runner, heartbeat, payload versions.
- **r1 (2026-11-07).** Initial draft.
