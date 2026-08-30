# Herdr Menubar SSH Remote Sessions — Evidence-Gated Design

**Date:** 2026-08-29  
**Status:** Approved design  
**Target workflow:** an existing `herdr --remote <ssh-config-alias>` attachment in WezTerm  
**Excluded workflow:** interactive `ssh <host>` followed by running Herdr remotely

## Purpose

Herdr Menubar should eventually monitor remote Herdr sessions, deliver their notifications, and focus the exact local WezTerm pane that owns a `herdr --remote` attachment. The first step is not implementation. It is a bounded feasibility spike on the Mac and SSH host where the workflow is actually used.

The spike must prove the complete transport and focus path before production code is authorized:

1. noninteractive remote session discovery;
2. OpenSSH Unix-socket forwarding to each remote public Herdr socket;
3. public API requests and subscriptions through the forwarded socket;
4. exact remote pane focus;
5. remote title-marker propagation to the local thin client;
6. exact existing WezTerm-pane activation;
7. repeatable tunnel creation; and
8. complete restoration and cleanup.

If every mandatory gate passes, the agent on that Mac may proceed to a reviewed design, TDD plan, and implementation on an isolated branch. A failed or ambiguous mandatory gate blocks implementation and produces a sanitized evidence report for review here.

## User decisions

- The spike runs on the Mac with WezTerm, the Herdr Menubar repository, and access to the work SSH host.
- Only the normal `herdr --remote <alias>` workflow is in scope.
- The user establishes and owns the existing interactive `herdr --remote` attachment.
- Remote hosts are connected and disconnected manually in the eventual product.
- Herdr Menubar uses normal OpenSSH configuration and `ssh-agent`; it stores no credentials.
- A connected endpoint monitors every running remote Herdr session.
- After an app restart, Herdr Menubar asks before reconnecting endpoints that were connected previously.
- Phase 1 is evidence-only. It makes no repository changes, installs no packages, and returns its sanitized report in the agent's final response.
- If Phase 1 passes, the local agent may design and implement there. If it does not pass cleanly, it stops and returns the evidence.

## Why StreamLocal forwarding is the preferred transport

Each Herdr session exposes an owner-only public Unix socket. OpenSSH supports forwarding a local Unix socket to a remote Unix socket:

```text
ssh -N -T -L <private-local.sock>:<remote-herdr.sock> <alias>
```

This preserves Herdr's public newline-delimited JSON API and allows the existing `HerdrClient`, subscription, snapshot, notification, focus, and retry behavior to operate on a local socket without introducing TCP, TLS, or a second protocol.

Herdr's existing `--remote` bridge is not itself the Menubar transport. It carries the private binary TUI client protocol over SSH. The spike instead forwards each remote session's public `herdr.sock` while relying on the already-attached thin client to receive the title marker used for exact local WezTerm focus.

Direct TCP is out of scope. Polling remote commands is acceptable for the discovery spike but not as the production monitoring transport. Consuming Herdr's private TUI protocol is forbidden.

## Phase 1 boundary and safety rules

### Allowed

- Inspect local repository status and installed tool versions.
- Inspect only the effective SSH configuration booleans needed by the spike.
- Run bounded, noninteractive SSH commands through `/usr/bin/ssh`.
- Query remote Herdr versions, API schema, and running session metadata.
- Create one private temporary directory, owned child SSH processes, and owner-only local Unix sockets.
- Exercise public Herdr snapshot, subscription, reserved-idle-pane focus, and exclusively owned title APIs.
- Activate existing WezTerm panes and restore the original pane.
- Produce a sanitized evidence report.

### Forbidden

- Do not launch `herdr --remote`. It can prompt to install, replace, or restart remote Herdr and may stop remote shells, development servers, or tests.
- Do not accept an install, replacement, restart, authentication, host-trust, or approval prompt. Stop and ask the user.
- Do not alter local or remote SSH configuration.
- Do not disable host-key verification.
- Do not inspect or copy private keys.
- Do not start or stop remote Herdr sessions.
- Do not expose a Herdr socket over TCP.
- Do not use a shell command string for SSH targets, paths, session names, pane IDs, or markers.
- Do not focus any pane that is not a user-reserved, non-agent `idle` pane. `pane.focus` can mark attention as seen, and a working pane can change state during the spike.
- Do not create a WezTerm tab or choose a fallback pane.
- Do not kill a process the orchestrator did not create and retain by direct child handle.
- Do not edit the repository, install dependencies, merge, push, or replace the stable installed app during Phase 1.

The focus and title checks are reversible mutations rather than strictly read-only actions. Focus is permitted only between two user-reserved, non-agent `idle` panes. The title check is permitted only after the user confirms that no other tool or client currently owns an API title override for that remote session and that the normal configured title is visible. The orchestrator then has exclusive title-API ownership until it clears its marker. If either exclusive-ownership premise cannot be established, G7 and G8 are `AMBIGUOUS` and no title mutation occurs.

## Preconditions

The agent must confirm all of the following before opening a tunnel:

- The repository commit, branch, and cleanliness are recorded.
- `python3` is already installed; the probe uses only the standard library.
- `/usr/bin/ssh`, local `herdr`, and the WezTerm CLI are executable.
- A user-established `herdr --remote <alias>` attachment is already working.
- The spike runs in a separate WezTerm pane connected to the same GUI instance.
- `WEZTERM_PANE` and `WEZTERM_UNIX_SOCKET` are present.
- The selected remote session contains a focused user-reserved, non-agent `idle` pane and a distinct user-reserved, non-agent `idle` alternate.
- A different existing local WezTerm pane is available as a focus distractor.
- The user confirms no existing API title override is active for the selected remote session and agrees not to run another title-API client during the bounded marker test.

If the working attachment or safe-pane arrangement is absent, the agent asks the user to prepare it. It does not automate setup.

The SSH alias is treated as one opaque argv value. Reject an empty value, a value beginning with `-`, or one containing NUL, newline, carriage return, or control characters. Host, user, port, identity, and ProxyJump belong in `~/.ssh/config`, not in the spike's command construction.

Run `ssh -G <alias>` only to derive required booleans. Do not include expanded hostname, username, IP address, key paths, or proxy command in the report. If the effective alias contains `LocalForward`, `RemoteForward`, or `DynamicForward`, stop and require a dedicated alias without unrelated forwards. OpenSSH cannot clear configured forwards while preserving the command-line StreamLocal `-L` used by the tunnel. Record only that the configured multiplexing/background values were inspected; every actual spike invocation overrides them with `ControlPath=none`, `ControlMaster=no`, `ControlPersist=no`, and `ForkAfterAuthentication=no`.

## Temporary orchestrator

The agent creates one standard-library Python orchestrator inside a directory created like:

```text
/tmp/herdr-ssh-spike.<random>/
```

The root must be mode `0700`, owned by the current UID, and recorded by standardized path, device, and inode. It may contain only explicitly registered files such as:

```text
probe.py
api-<ordinal>.sock
tunnel-<ordinal>.stderr
```

The orchestrator must provide:

- direct argv execution with `shell=False`;
- `stdin=DEVNULL` for every SSH process;
- a 20-second total deadline for one-shot commands;
- concurrent stdout/stderr drains that terminate the child immediately when either cap is first exceeded;
- a retained-prefix cap of 1 MiB for stdout and 256 KiB for stderr, with discarded bytes never accumulated elsewhere;
- bounded terminate, two-second wait, kill, and final wait for owned children;
- tunnel stdout redirected to `/dev/null` and tunnel stderr continuously drained with the same immediate overflow termination and capped prefix;
- five-second Unix-socket connect/request deadlines;
- one-line JSON reads capped at 1 MiB;
- strict UTF-8 and JSON-object validation;
- exact request-ID correlation;
- an eight-second subscription-event deadline;
- signal handlers and an idempotent `finally` cleanup path registered before the first tunnel or title change.

The orchestrator stores raw responses only in memory or its private temp root. It never prints raw SSH configuration, socket paths, JSON payloads, pane titles, CWDs, commands, terminal contents, or stderr.

## SSH invocation policy

One-shot discovery commands use direct argv with these effective safeguards:

```text
/usr/bin/ssh
  -T -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
  -o ForwardAgent=no
  -o ForwardX11=no
  -o PermitLocalCommand=no
  -o ControlPath=none
  -o ControlMaster=no
  -o ControlPersist=no
  -o ForkAfterAuthentication=no
  -o ClearAllForwardings=yes
  <alias>
  <fixed remote herdr argv>
```

The tunnel invocation uses the same safety options except `ClearAllForwardings`, plus:

```text
  -N
  -o ExitOnForwardFailure=yes
  -o StreamLocalBindMask=0177
  -o StreamLocalBindUnlink=no
  -L <fresh-local-socket>:<validated-remote-socket>
```

The arguments are passed as an array. The spike never interpolates them into a shell string.

Before G3 can pass, the orchestrator must prove that the effective invocation has multiplexing disabled and cannot background itself. A retained SSH child that exits while another master or listener continues is `FAIL`, not successful reuse.

## Discovery and compatibility proof

The probe runs bounded fixed remote commands equivalent to:

```text
herdr --version
herdr session list --json
herdr api schema --json
```

It also records the local Herdr and WezTerm versions. A noninteractive remote `PATH` failure is `AMBIGUOUS`; do not guess `/usr/local/bin`, `/opt/homebrew/bin`, or another remote binary path.

The agent inspects the actual installed schema and live responses. It must not invent fallback method names or response keys. Version mismatch is evidence rather than an automatic failure if every live protocol gate succeeds.

Session discovery must be bounded and strictly parsed while tolerating unknown fields. Each running session must have a unique identity, `running == true`, and an absolute `socket_path`. Reject paths containing NUL, CR, LF, colon, percent, dollar sign, or control characters so OpenSSH cannot perform token or environment expansion. Measure paths as UTF-8 bytes. Require the generated local socket to fit the local platform's measured `sockaddr_un.sun_path` capacity including its terminator, and conservatively reject a reported remote path longer than 103 UTF-8 bytes. A longer existing remote socket is `AMBIGUOUS` for this transport rather than permission to guess quoting behavior. Never derive a socket path from a session name. Cap the spike at 64 sessions.

The required live public API surface is the installed schema's form of:

- `ping`
- `session.snapshot` and/or the schema's pane/workspace/tab list methods used by the current client
- `events.subscribe` accepting the exact current Menubar subscription set: global `pane.created`, `pane.closed`, `pane.focused`, `pane.moved`, `pane.exited`, `pane.agent_detected`, `workspace.renamed`, and `tab.renamed`, plus one `pane.agent_status_changed` subscription for every current pane
- `pane.focus`
- `client.window_title.set`
- `client.window_title.clear`

If the installed schema lacks a required capability, stop instead of adapting the architecture during the spike.

## Per-session StreamLocal proof

For each discovered running session, sequentially:

1. Allocate a fresh short local socket path in the private root.
2. Start one direct child StreamLocal tunnel.
3. Wait at most ten seconds for the local filesystem entry while checking the child remains alive.
4. Require a Unix socket owned by the current UID with no group or world permission bits.
5. Send a schema-valid `ping` and require a correlated successful response.
6. Fetch the schema-valid session/pane, workspace, and tab state needed by the existing Menubar client.
7. Stop and reap the exact tunnel child, remove only its recorded socket, and verify no listener remains.

A listener file alone does not prove forwarding. The public API round trips must succeed.

Every running session must pass transport and snapshot validation. If the host has only one running session, report live multi-session validation as `NOT EXERCISED (non-blocking)`. Conditional implementation must then include a hermetic two-remote-session fixture and a later multi-session live smoke before merge.

## Subscription and reversible remote focus proof

Run the active-session proof in this order:

1. Capture a baseline snapshot and tokenize the original reserved idle focused pane and a distinct reserved idle alternate.
2. Open a dedicated forwarded socket and send the installed-schema `events.subscribe` request for the exact production subscription set listed above.
3. Require a correlated subscription acknowledgement before focusing.
4. Immediately re-read both panes and require that they are still non-agent `idle`. Subscribe to their `pane.agent_status_changed` events as part of the production set.
5. On a separate request connection, send `pane.focus` for the alternate.
6. Require the exact response ID and target pane.
7. Require a matching pushed `pane.focused` event.
8. Fetch a new snapshot and require that the alternate is focused and both reserved panes remain non-agent `idle`.
9. In `finally`, re-read the original pane. If it remains non-agent `idle`, focus it and verify it in a fresh snapshot. If it is no longer safe, do not send `pane.focus`; keep the tunnel alive, ask the user to restore it through the existing Herdr UI, verify the user-directed restoration by snapshot, and fail G6/G8.

An explicit server error is `FAIL`. An acknowledged subscription without the expected event is `AMBIGUOUS`. Any agent-status change for a reserved pane aborts further automated focus. If the original pane becomes unsafe after focus has changed, keep the tunnel alive, ask the user to restore focus through the existing Herdr UI, verify that restoration by snapshot, and classify G6/G8 as `FAIL`. The agent must not violate the idle-only rule merely to automate restoration.

## Title propagation and exact WezTerm focus proof

Generate an unpredictable marker such as:

```text
herdr-menubar-spike-<lowercase UUID>
```

Construct its JSON with the language JSON library. Then:

1. Before any title call or requested user interaction, capture the immutable pre-test active local pane from same-instance `wezterm cli list-clients --format json` and require one unambiguous client/pane mapping.
2. Reconfirm exclusive title-API ownership and the user-confirmed normal-title baseline. There is no safe getter for a prior API override; without this confirmation, do not call `set`.
3. Call `client.window_title.set` through the forwarded public API.
4. Require the installed-schema success response.
5. If the response reports no foreground client, ask the user to interact once with the existing remote attachment and retry exactly once. A second failure is `AMBIGUOUS`; the immutable baseline from step 1 does not change.
6. Poll `wezterm cli list --format json` for at most one second.
7. Require exactly one local pane whose title exactly equals the marker. Zero is `AMBIGUOUS`; more than one is `FAIL`.
8. Select an existing distractor distinct from the matched target, activate it, then require `list-clients.focused_pane_id` to equal the distractor and require human or Computer Use confirmation that it is visible.
9. Clear the marker with bounded retries and verify it disappears before target activation.
10. Run `wezterm cli activate-pane --pane-id <exact matched pane>`.
11. Require `list-clients.focused_pane_id` to equal the exact matched pane and require the user or Computer Use to confirm that the correct pre-existing `herdr --remote` tab and expected remote pane became visible.
12. Restore the immutable pre-test local pane from step 1, verify it through `list-clients`, and visibly confirm restoration.

The human or Computer Use observation is authoritative because `wezterm cli list` has no active-pane flag and multiple clients or instances may exist. CLI exit status alone is insufficient. Do not create a tab and do not focus a fallback.

Repeat the selected session's tunnel-create, public-API, stop, and cleanup cycle twice to prove reconnectability.

## Cleanup order and ownership

Cleanup runs while the tunnel is still alive:

1. Revalidate the original reserved pane. If it remains non-agent `idle`, restore it automatically and verify it by snapshot. If it became unsafe, do not issue `pane.focus`; keep the tunnel alive, require user-directed restoration, verify it by snapshot, and fail G6/G8.
2. Clear any possible marker with bounded retries and verify no exact marker remains.
3. Close subscription and request sockets.
4. Restore the immutable pre-test local WezTerm pane and verify it through the same-instance `list-clients` view.
5. Terminate and await the exact retained tunnel child; kill and await it only after the bounded grace period.
6. Verify the child is gone and no process holds the created socket.
7. Verify every remaining temp-root entry is expected, same-owner, and of the expected file/socket type.
8. Unlink explicit entries and remove only the recorded root after checking path, device, and inode.
9. Verify zero owned children, listeners, sockets, markers, and temporary files remain.

Never clean up from a stale PID alone, unlink an unexpected replacement socket, or recursively delete an unresolved path. If interrupted, cleanup is the next action before any continued testing.

## Mandatory decision gates

| Gate | Required proof |
|---|---|
| G1 — Existing attach | The user-established `herdr --remote` attachment works with no agent-triggered prompt or remote change. |
| G2 — Discovery | BatchMode version, schema, and session discovery succeed with safe, valid data. |
| G3 — Tunnel transport | Every running session receives an owner-only StreamLocal socket and successful public API round trip. |
| G4 — State compatibility | Required pane/workspace/tab state matches the installed schema and can drive the current client model. |
| G5 — Subscription | The exact current production subscription set is acknowledged and one real matching `pane.focused` event succeeds. |
| G6 — Remote focus | Exact safe-pane focus and verified restoration both succeed. |
| G7 — Local exact focus | Exclusive/no-prior title ownership is confirmed; a unique marker reaches one pane; a different distractor is activated and verified first; the target then activates and verifies exactly; marker and original focus are restored. |
| G8 — Lifecycle cleanup | A second cycle succeeds and all remote/local focus, marker, child, socket, and temp state is restored. |

Every mandatory gate must be `PASS` before implementation is authorized.

- `FAIL`: a definitive unsupported or incorrect result.
- `AMBIGUOUS`: evidence is incomplete, environment-dependent, prompted, mismatched, or cannot prove exact behavior.
- `NOT EXERCISED`: allowed only for live multi-session coverage when exactly one remote session is running.

Any `FAIL` or `AMBIGUOUS` gate produces `STOP — RETURN EVIDENCE`. Do not silently downgrade to monitoring-only or implement a compatibility guess.

If StreamLocal forwarding is blocked, the preferred alternative is a supported public JSON API stdio bridge added to Herdr core. Do not use the private TUI protocol, polling as the production transport, or TCP exposure.

## Conditional implementation authorization

Only `G1` through `G8` all passing authorizes implementation on the other Mac.

The agent then:

1. fetches current `origin/master`;
2. creates an isolated feature branch and worktree;
3. writes a production design document grounded in the recorded evidence;
4. runs an independent spec review to approval, with at most three remediation loops; exhaustion stops implementation and returns the findings;
5. writes and independently reviews a TDD implementation plan to approval, again stopping after three unsuccessful remediation loops;
6. confirms a clean baseline and full test suite; any failure blocks implementation until independently resolved;
7. implements task-by-task with RED, GREEN, refactor, spec review, and quality review;
8. runs hermetic multi-endpoint integration, stress, TSan, Release, Analyze, signing, privacy, process, and socket cleanup checks; and
9. repeats the real-host smoke before requesting merge.

Passing the spike does not authorize merging, pushing, replacing the stable installed app, changing remote configuration, or handling prompts. Those require a separate user request.

## Expected production architecture after a passing spike

### Remote endpoint and identity

Persist a `RemoteEndpoint` containing only:

- stable UUID;
- friendly label;
- opaque validated SSH target; and
- prior-connected intent.

Never store credentials, keys, resolved host/IP, socket paths, or pane state. Friendly-label edits do not change identity.

Session identity becomes host-qualified:

```text
(origin: local | remote(endpoint UUID), session: default | named(name))
```

This identity must flow through supervisor dictionaries, menu rows, unavailable state, focus and refresh routing, notifications, notification payloads, and current-run shortcut targets. Duplicate local and remote session/pane IDs remain independent. Backward compatibility for old notification payloads is not required.

### Discovery and tunnel ownership

`SSHDiscoveryClient` runs bounded one-shot BatchMode discovery approximately every 15 seconds with bounded backoff. A failed discovery retains healthy existing tunnels; a successful snapshot may remove stopped sessions.

One `RemoteEndpointManager` actor per connected endpoint owns:

- discovery generation and retry state;
- cached remote descriptors and categorical diagnostics;
- one `ManagedSSHTunnel` per running session; and
- cancellation, restart, removal, and shutdown barriers.

One endpoint's failure never blocks local discovery or another endpoint.

`ManagedSSHTunnel` uses `/usr/bin/ssh` with argv only, bounded output, owner-only short sockets, no TCP, no prompts, and exact-child termination/reaping. A production design may use an app-owned unique `ControlMaster` and `ControlPath` with `ControlPersist=no` plus a private identity-checked manifest so a later launch can verify and close a crash orphan. It must never kill a stale PID or remove an unverified socket.

`RemoteSessionRegistry` publishes cached forwarded descriptors into composite discovery. Local filesystem discovery remains fast and authoritative and never waits on network SSH. Forwarded paths remain stable during a session's current app-run identity because the existing supervisor does not recreate a client merely because a descriptor's socket URL changes.

### Mandatory production framing hardening

The current local `JSONLineFramer` retains an unbounded partial line, and `HerdrConnectionState` retains an unbounded queue of completed lines. A passed spike authorizes implementation work but does not authorize publishing a remote descriptor to `HerdrClient` until this boundary is hardened and independently reviewed.

Before the first remote session can connect, production must add:

- a hard maximum encoded JSON line length;
- a hard total queued-byte limit and queued-event/line count;
- incremental enforcement before appending or queueing additional data;
- immediate connection closure and normal bounded reconnect behavior on overflow;
- bounded logging that exposes only the overflow category, never payload content; and
- unit/integration tests for an unterminated oversized line, many individually valid queued lines, overflow while a reader is suspended, exact close-once behavior, and successful recovery on a new connection.

### Lifecycle and user experience

- Local monitoring starts regardless of remote state.
- Adding an endpoint never connects automatically.
- Connect is explicit and sets prior-connected intent after success.
- Disconnect cancels discovery and retries, removes that endpoint's sessions immediately, stops and awaits its tunnels, and clears prior-connected intent.
- Transient tunnel or network loss uses the existing ten-second exact-target grace and reconnect behavior.
- Retry affects only the selected endpoint/session backoff.
- Before any remote network contact after launch, the app cleans only verified stale app-owned tunnel masters and shows one aggregated prompt for previously connected friendly labels.
- **Reconnect** starts all listed endpoints.
- **Not Now** skips them for the current launch but preserves intent for the next launch.
- The local status item and local session monitoring remain usable while consent is pending.

Add a `Remote Hosts…` window for Add, Edit, Remove, Test Connection, Connect, and Disconnect. It accepts a friendly label and SSH config alias and exposes safe categorical status only. Session headings retain status-first grouping and use labels such as `Work · Default` and `Work · agents`; local labels remain unchanged. Notifications use the friendly endpoint label, never the raw target. Errors are categorized as authentication, host trust, forwarding, Herdr unavailable, or no sessions, while raw details remain private.

## Production verification requirements

At minimum, tests must cover:

- endpoint, target, socket-path, and untrusted-JSON validation;
- host-qualified equality, sorting, labels, focus, refresh, notifications, and shortcut routing;
- notification payload versioning;
- no remote contact before explicit connect or restart consent;
- reconnect and Not Now behavior;
- manual disconnect and immediate removal;
- stale generation and callback rejection;
- failed discovery retaining healthy tunnels;
- successful discovery removing stopped sessions;
- independent endpoint and session backoff;
- TERM-ignoring child termination/reaping;
- stdout/stderr overflow and timeout cleanup;
- identity-checked control-socket orphan cleanup;
- marker cleanup under cancellation;
- absence of shell invocation, TCP listeners, credential storage, and public sensitive logging;
- local plus two remote sessions with duplicate session and pane IDs;
- independent events, notifications, shortcuts, exact focus, endpoint loss, grace reconnect, removal, and shutdown.

The final release gate includes stress tests, Thread Sanitizer, the full suite, universal Release, Analyze, signature verification, process/socket/temp cleanup, and a repeated real-host smoke.

## Sanitized evidence report

The spike returns a Markdown report in its final agent response with this shape. It must not retain the report inside the temp root that cleanup deletes. If the user explicitly asks for a file, write only the already-sanitized report to an explicit user-approved path with mode `0600`; that file is outside the temp-artifact cleanup inventory.

```markdown
# Herdr Menubar SSH Feasibility Report

## Environment
- Date:
- Repository commit / branch / clean:
- macOS:
- Local Herdr version:
- Remote Herdr version:
- WezTerm version:

## Guardrails
- Existing user-established attachment confirmed:
- No prompts/config changes/package installs:
- Private temp root and direct-child ownership confirmed:

## Redacted setup
- Endpoint: <REMOTE>
- Running session count:
- Safe focus session prepared:
- Live multi-session exercised: YES / NOT EXERCISED

## Gates
| Gate | Result | Sanitized evidence | Duration |
|---|---|---|---|
| G1 | PASS/FAIL/AMBIGUOUS | ... | ... |
...

## Per-session transport
| Session token | Kind | Secure socket | API state | Subscription/focus exercised |
|---|---|---|---|---|

## Exact-focus evidence
- Focus response correlated:
- Matching event observed:
- Post-focus snapshot matched:
- Unique marker match count:
- Marker clear verified:
- `list-clients` corroboration:
- Human/Computer Use confirmation:
- Remote focus restored:
- Local focus restored:

## Lifecycle and cleanup
- Repeat-cycle result:
- Owned children before/after:
- Owned sockets before/after:
- Marker residue:
- Temp-root residue:

## Findings and deviations
- Facts only; no raw hosts, paths, IDs, titles, CWDs, content, or stderr.

## Decision
PASS — IMPLEMENTATION AUTHORIZED HERE
or
STOP — RETURN EVIDENCE
```

When the decision is `PASS`, the Phase 1 report records any unexercised live multi-session condition. A separate later implementation report may list design, plan, and review commits. When Phase 1 is `STOP`, it records the exact blocking gate, safest next alternative, and confirms that no production files changed.

## Source anchors

- Herdr remote workflow and install/restart behavior: `src/remote/attach.rs` in Herdr commit `7b675f42af35508eab66ac42fe1598628597a893`.
- Herdr private remote bridge: `src/remote/host_unix.rs` at the same commit.
- Herdr public API methods and events: `src/api/schema.rs` and `src/api/schema/events.rs` at the same commit.
- Herdr title propagation and foreground-client behavior: `src/server/headless.rs` and `src/client/mod.rs` at the same commit.
- Herdr focus/seen behavior: `src/app/api/panes.rs` at the same commit.
- Existing Menubar exact focus contract: `docs/superpowers/specs/2026-08-15-herdr-menubar-wezterm-session-focus-design.md`.
- OpenSSH Unix-socket forwarding and configuration: `ssh(1)`, `ssh_config(5)`, and `sshd_config(5)`.
- WezTerm CLI list, list-clients, instance targeting, and activate-pane documentation.
