# Herdr Menubar SSH Remote Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the real `herdr --remote <ssh-config-alias>` path on the target Mac, then—only if every evidence gate passes—add manually managed remote Herdr endpoints whose sessions participate in the existing menu, notifications, shortcuts, grace handling, and exact WezTerm focus flow.

**Architecture:** Phase 1 is a repository-read-only spike: bounded OpenSSH Unix-socket forwards expose each remote Herdr public socket locally, and an existing remote thin client propagates an exact temporary title marker to its owning WezTerm pane. Phase 2 is conditional: harden transport framing first, host-qualify session identity, keep network discovery in endpoint-owned actors, publish only cached stable forwarded descriptors to the existing supervisor, and compose explicit connect/disconnect/restart-consent UI into `ApplicationRuntime`.

**Tech Stack:** Swift 6, Swift concurrency actors, Observation, AppKit, SwiftUI, Network.framework Unix sockets, `/usr/bin/ssh`, POSIX process ownership, UserDefaults, UserNotifications, WezTerm CLI, XCTest, Xcode 26/macOS 26, Python 3 standard library for the temporary feasibility probe.

**Design spec:** `docs/superpowers/specs/2026-08-29-herdr-menubar-ssh-remote-sessions-design.md`

---

## Non-negotiable execution boundary

This plan has two phases. Do not combine them.

1. **Phase 1 — evidence only:** run Tasks 0–1 on the Mac that has the real work SSH alias and existing `herdr --remote` attachment. Do not edit the repository, install software, change SSH configuration, launch `herdr --remote`, or accept a prompt.
2. **Decision gate:** implementation is authorized only when G1–G8 in the design spec are all `PASS`. `NOT EXERCISED` is allowed only for live multi-session coverage when the host has exactly one running session. Any `FAIL` or `AMBIGUOUS` result ends the run with `STOP — RETURN EVIDENCE`.
3. **Phase 2 — conditional implementation:** Tasks 2–14 run only after the decision is `PASS`. Passing the spike authorizes a feature branch and local implementation; it does not authorize merge, push, stable-app replacement, remote configuration changes, or accepting SSH/Herdr prompts.

If Phase 1 stops, return the sanitized report from Task 1 and do not create a feature worktree or production commit.

## Worktree and baseline after a PASS

Create the implementation worktree only after Task 1 reports `PASS — IMPLEMENTATION AUTHORIZED HERE`:

```bash
git fetch --prune
git worktree add .worktrees/ssh-remote-sessions -b codex/ssh-remote-sessions origin/master
cd .worktrees/ssh-remote-sessions
git status --short --branch
```

Expected: the branch is `codex/ssh-remote-sessions`, it starts at current `origin/master`, and the worktree is clean. Copy the approved design and this plan into the branch only if they are not already present on `origin/master`; preserve their history rather than recreating them.

Before production edits, run:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
git diff --check
```

Expected: the complete non-UI suite passes and `git diff --check` emits no output. A baseline failure blocks implementation; diagnose it separately and do not reinterpret it as an SSH-feature RED.

Reconcile the approved design against the Phase 1 report before Task 2. Add a sanitized evidence appendix recording the observed Herdr versions/protocol shapes and every gate result. If live evidence changes any transport, schema, lifecycle, or focus assumption, revise the design first. In either case, dispatch a fresh independent spec reviewer and then a fresh plan reviewer; both must return `APPROVED` before production code. Stop after three unsuccessful remediation loops for either review and return the unresolved findings.

## File map

| File | Responsibility |
| --- | --- |
| `HerdrMenubar/Herdr/JSONLineFramer.swift` | Enforce a hard partial/complete JSON-line byte limit incrementally |
| `HerdrMenubar/Herdr/HerdrConnection.swift` | Bound queued lines and bytes; close exactly once on overflow |
| `HerdrMenubar/Herdr/SessionDiscovery.swift` | Host-qualified session identity, local convenience constructors, and local discovery |
| `HerdrMenubar/Herdr/SessionSupervisor.swift` | Exact host-qualified routing plus immediate endpoint removal and targeted retry |
| `HerdrMenubar/Remote/RemoteEndpoint.swift` | Persistable endpoint identity, friendly label, validated opaque SSH target, intent, and safe status categories |
| `HerdrMenubar/Remote/RemoteEndpointStore.swift` | Versioned UserDefaults persistence of endpoint configuration only |
| `HerdrMenubar/Remote/SSHInvocation.swift` | Direct-argv SSH policy, target/path validation, and sanitized error classification |
| `HerdrMenubar/Remote/SSHDiscoveryClient.swift` | Bounded noninteractive version/schema/session discovery and untrusted JSON decoding |
| `HerdrMenubar/Remote/TunnelWorkspace.swift` | Manager-owned stable per-run/per-session socket slots and identity-checked final removal |
| `HerdrMenubar/Remote/ManagedSSHTunnel.swift` | Long-lived exact-child tunnel, owner-only local socket, bounded output, control-socket manifest, and shutdown |
| `HerdrMenubar/Remote/RemoteSessionRegistry.swift` | Actor-owned cached remote descriptors, read synchronously by composite scans |
| `HerdrMenubar/Remote/RemoteEndpointManager.swift` | One endpoint's discovery loop, per-session tunnels, restart/backoff, and teardown barrier |
| `HerdrMenubar/Remote/RemoteSessionsController.swift` | Own all endpoint managers, explicit connect/disconnect/test actions, restart consent, and aggregate status |
| `HerdrMenubar/Remote/CompositeSessionDiscovery.swift` | Merge authoritative local discovery with the registry cache without network waits |
| `HerdrMenubar/Remote/RemoteHostsView.swift` | Add/edit/remove/test/connect/disconnect window using friendly labels and categorical errors |
| `HerdrMenubar/Remote/RemoteHostsWindowController.swift` | Reuse and terminate one Remote Hosts window |
| `HerdrMenubar/Notifications/NotificationModels.swift` | Host-qualified notification target contract |
| `HerdrMenubar/Notifications/NativeNotificationService.swift` | Payload version 2 encoding/decoding for endpoint-qualified targets |
| `HerdrMenubar/Status/AgentStore.swift` | Preserve exact remote identity and drain per-origin selection/marker work before removal |
| `HerdrMenubar/Menu/StatusMenuPresentation.swift` | Remote Hosts action and friendly endpoint-qualified section labels |
| `HerdrMenubar/App/ApplicationRuntime.swift` | Compose local + remote graph, reconnect consent, actions, startup, and terminal shutdown |
| `HerdrMenubar/App/HerdrMenubarApp.swift` | App-delegate presentation of the one aggregated reconnect prompt |
| `HerdrMenubarTests/Remote*Tests.swift` | Endpoint, persistence, SSH, tunnel, manager, registry, UI, and lifecycle tests |
| `HerdrMenubarTests/MultiSessionIntegrationTests.swift` | Local + two remote duplicate-ID routing and outage/reconnect integration |
| `HerdrMenubarTests/HerdrConnectionTests.swift` | Queue overflow, close-once, and reconnect recovery |
| `HerdrMenubarTests/JSONLineFramerTests.swift` | Oversized partial and complete line boundaries |
| `HerdrMenubarTests/NativeNotificationServiceTests.swift` | Payload v2 round trip and old-payload rejection |
| `HerdrMenubarTests/ApplicationRuntimeTests.swift` | Consent-before-contact, action ownership, and stop barriers |
| `HerdrMenubar.xcodeproj/project.pbxproj` | `Remote` source/test group membership |
| `README.md` | Configuration, consent, isolation, focus path, and limitations |

Reserve one unused PBX identifier family after inspecting the project; record the chosen prefix at the top of the first project-file diff and allocate every file-reference/build-file pair exactly once. Do not reuse the existing notification, shortcut, or integration ID families.

## Shared test rules and commands

Every production task follows strict RED → GREEN → refactor:

- Add the complete behavior test and deterministic fake/gate first.
- Run the focused test and capture the missing-type or behavioral failure.
- Make the smallest production change that passes it.
- Stress concurrency-sensitive tests with `-test-iterations`; use continuations/observable counts, never fixed sleeps or fixed `Task.yield()` counts as ordering proof.
- Run `git diff --check`, inspect the exact staged diff, and commit only that task.
- Dispatch separate spec-compliance and quality reviews after each task. Remediate findings in separate commits. Three unsuccessful review loops stop execution and return the findings.

Focused test template:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests/TestClassName
```

Full non-UI suite:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

---

## Phase 1 — evidence only

### Task 0: Establish safe ownership and prepare the temporary probe

**Repository files:** none. Do not create, modify, stage, or commit repository content.

- [ ] **Step 1: Record the local baseline without changing it**

Record `git rev-parse HEAD`, `git branch --show-current`, `git status --short`, macOS version, local Herdr version, WezTerm version, and whether `python3`, `/usr/bin/ssh`, local `herdr`, and the WezTerm CLI are executable. Keep hostnames, resolved addresses, key paths, pane IDs, titles, CWDs, and socket paths out of the report.

- [ ] **Step 2: Obtain the operator inputs and enforce preconditions**

Require one existing user-established `herdr --remote <alias>` attachment, two user-reserved non-agent `idle` panes in its selected Herdr session, a different existing WezTerm pane as distractor, `WEZTERM_PANE`, `WEZTERM_UNIX_SOCKET`, explicit confirmation that no API title override is active, and visible confirmation that the normal configured title is currently present. The agent must not launch the attachment or prepare the remote panes itself.

Treat the SSH alias as one argv value and reject empty, leading `-`, NUL, CR, LF, or control characters. Run `/usr/bin/ssh -G` only to derive booleans. Stop if the effective alias has LocalForward, RemoteForward, or DynamicForward. Do not report expanded host/user/IP/key/proxy values.

- [ ] **Step 3: Create one private temporary root and one standard-library orchestrator**

Use `tempfile.mkdtemp(prefix="herdr-ssh-spike.", dir="/tmp")`, immediately set mode `0700`, and record its path/device/inode/UID for later identity checks. The script must define these concrete operations:

```python
run_bounded(argv, deadline_s=20, stdout_limit=1_048_576, stderr_limit=262_144)
start_tunnel(argv, stderr_limit=262_144)
request_json_line(socket_path, request, deadline_s=5, line_limit=1_048_576)
subscribe_json_lines(socket_path, request, deadline_s=8, line_limit=1_048_576)
terminate_owned(child, term_grace_s=2, kill_grace_s=2)
cleanup_registered_artifacts()
```

Implement each process with direct argv, `shell=False`, `stdin=DEVNULL`, concurrent bounded drains, terminate-on-first timeout/overflow, bounded TERM/KILL/reap, and a retained `Popen` handle. Tunnel stdout is `DEVNULL`; tunnel stderr is continuously drained and capped. Register signal handlers plus idempotent `finally` cleanup before opening a tunnel or setting a title.

Every JSON request uses a generated exact request ID, one compact object plus newline, strict UTF-8, a one-line cap, a JSON-object root, and exact ID correlation. Raw data remains only in memory/private temp storage and is destroyed after deriving sanitized booleans/counts/categories.

- [ ] **Step 4: Validate the probe before remote contact**

Unit-exercise the temporary helpers locally with a child that exits, a child that exceeds each output cap, a child that ignores TERM, a fake Unix JSON-line server, an oversized unterminated line, a mismatched response ID, and double cleanup. Require bounded return, exact-child reaping, no continuation/thread left waiting, and zero temp residue other than the registered probe file before proceeding.

Expected: helper checks pass without a remote connection. Any unbounded wait or ownership ambiguity is `STOP — RETURN EVIDENCE`.

### Task 1: Run G1–G8 and return the sanitized decision

**Repository files:** none. The final report is returned in the agent response, not written into the repository or the temporary root.

- [ ] **Step 1: Run bounded remote discovery**

Use direct argv for remote `herdr --version`, `herdr session list --json`, and `herdr api schema --json`. Every connecting invocation includes:

```text
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
```

One-shot discovery also includes `-o ClearAllForwardings=yes`. Require unique running sessions and their emitted absolute socket paths. Reject more than 64 sessions; NUL/CR/LF/colon/percent/dollar/control characters; paths longer than 103 UTF-8 bytes; or generated local paths that do not fit measured local `sockaddr_un.sun_path` capacity.

- [ ] **Step 2: Prove every running session's public transport**

Sequentially start a fresh direct child with `-N`, `ExitOnForwardFailure=yes`, `StreamLocalBindMask=0177`, `StreamLocalBindUnlink=no`, and one `-L <private-local.sock>:<validated-remote.sock>`. Require a same-UID owner-only Unix socket, an alive retained child, correlated `ping`, and the installed-schema pane/session, workspace, and tab state used by `HerdrClient`. Stop/reap/remove/verify each before moving to the next session.

The listener file alone is not evidence. If only one session exists, record live multi-session as `NOT EXERCISED`; do not fail G3 solely for that.

- [ ] **Step 3: Prove the production subscription set and reversible remote focus**

Against the user-selected session, subscribe to all current global events—`pane.created`, `pane.closed`, `pane.focused`, `pane.moved`, `pane.exited`, `pane.agent_detected`, `workspace.renamed`, `tab.renamed`—plus `pane.agent_status_changed` for every current pane. Require acknowledgement before mutation.

Revalidate both reserved panes as non-agent `idle`, focus the alternate, require correlated response, matching pushed `pane.focused`, and matching snapshot. Abort automated focus on any status change. In cleanup, auto-restore the original only if it still qualifies as non-agent `idle`; otherwise keep the tunnel alive, require user-directed restoration, verify by snapshot, and mark G6/G8 failed.

- [ ] **Step 4: Prove exact title propagation and WezTerm focus**

Before any title call or requested interaction, capture one immutable same-instance `list-clients.focused_pane_id`. After reconfirming exclusive title ownership, set an unpredictable marker through the public API and require exactly one exact-title match in `wezterm cli list --format json`. On `no_foreground_client`, request one user interaction and retry once.

Activate and verify an existing distractor distinct from the target through both same-instance `list-clients.focused_pane_id` and human or Computer Use visible confirmation. Clear the marker and verify its disappearance. Activate the exact matched target; require same-instance `list-clients.focused_pane_id` plus human or Computer Use confirmation of the correct existing `herdr --remote` tab and expected remote pane. Restore the immutable pre-test local pane and verify it through both same-instance `list-clients` and visible human or Computer Use confirmation.

- [ ] **Step 5: Repeat the tunnel lifecycle and clean everything**

Run a second create/API/stop cycle. While the tunnel is alive, conditionally restore remote focus, clear marker, close request/subscription sockets, restore local focus, terminate/reap the exact child, verify no listener, validate every temp entry by owner/type and the root by path/device/inode, unlink explicit entries, and remove the root. Never use recursive deletion or a stale PID.

- [ ] **Step 6: Apply the hard decision gate**

Produce the exact report shape from the design spec with G1–G8 results, sanitized evidence, durations, per-session ordinal tokens, focus proof, lifecycle proof, and before/after cleanup counts.

Expected outcomes:

```text
PASS — IMPLEMENTATION AUTHORIZED HERE
STOP — RETURN EVIDENCE
```

Only the first outcome permits Task 2. Any prompt, PATH guess, schema guess, unsafe restoration, missing normal-title confirmation, ambiguous title ownership, missing visible distractor/target/restoration observation, missing exact event, missing exact pane activation, cleanup residue, or other `FAIL`/`AMBIGUOUS` gate selects the second outcome.

---

## Phase 2 — conditional implementation after G1–G8 PASS

### Task 2: Bound JSON framing and receive queues before remote publication

**Files:**
- Modify: `HerdrMenubar/Herdr/JSONLineFramer.swift`
- Modify: `HerdrMenubar/Herdr/HerdrConnection.swift`
- Modify: `HerdrMenubarTests/JSONLineFramerTests.swift`
- Modify: `HerdrMenubarTests/HerdrConnectionTests.swift`

- [ ] **Step 1: Write framing and queue-overflow RED tests**

Add tests for an exact-limit complete line, limit+1 complete line, an unterminated line crossing the limit over many 64 KiB chunks, CRLF accounting, many individually valid lines crossing the queued-byte limit, queued-line-count overflow, overflow while a reader is suspended, close exactly once, and a fresh connection succeeding after overflow.

Use injectable small limits in tests:

```swift
let limits = HerdrTransportLimits(
    maximumLineBytes: 8,
    maximumQueuedBytes: 12,
    maximumQueuedLines: 2
)
```

Expected RED: `HerdrTransportLimits`, `.frameTooLarge`, `.receiveQueueOverflow`, and limit-aware initializers do not exist.

- [ ] **Step 2: Add explicit transport limits and throwing incremental framing**

Define:

```swift
struct HerdrTransportLimits: Equatable, Sendable {
    let maximumLineBytes: Int
    let maximumQueuedBytes: Int
    let maximumQueuedLines: Int

    static let live = HerdrTransportLimits(
        maximumLineBytes: 1_048_576,
        maximumQueuedBytes: 4_194_304,
        maximumQueuedLines: 1_024
    )
}

enum FramingError: Error, Equatable, Sendable {
    case incompleteLine
    case lineTooLong
}
```

Make `JSONLineFramer.init(maximumLineBytes:)` validate a positive limit. Change `append` to `mutating func append(_ data: Data) throws -> [Data]`. Process each incoming segment between newline bytes, checking `pending.count + segment.count <= maximumLineBytes` before appending; never append an over-limit segment first. Trim one CR only after extracting a complete line.

- [ ] **Step 3: Bound the connection queue and close on overflow**

Add `.frameTooLarge` and `.receiveQueueOverflow` to `TransportError`. Inject `HerdrTransportLimits.live` through `NWHerdrConnectionFactory` and `NWHerdrConnection` into `HerdrConnectionState`. Track `queuedBytes` beside `[Data]`.

When a reader is waiting, resume it directly with the first completed line. Before queueing each remaining line, require both:

```swift
lines.count + 1 <= limits.maximumQueuedLines
queuedBytes + line.count <= limits.maximumQueuedBytes
```

On either framing or queue overflow, transition once to failed, resume the one reader with the categorical error, clear queued data/counters, return `false`, and cancel the underlying `NWConnection`. Never log line data; log only the static overflow category privately/default-private.

- [ ] **Step 4: Run GREEN and regression suites**

Run `JSONLineFramerTests`, `HerdrConnectionTests`, and `HerdrClientTests`; stress the new overflow/reader races for 100 iterations. Then run the full suite.

Expected: all pass; memory retained by the framer and queue remains within the configured limits; connection cancel/failure is observed once.

- [ ] **Step 5: Commit**

```bash
git add HerdrMenubar/Herdr/JSONLineFramer.swift HerdrMenubar/Herdr/HerdrConnection.swift HerdrMenubarTests/JSONLineFramerTests.swift HerdrMenubarTests/HerdrConnectionTests.swift
git commit -m "fix: bound herdr transport buffering"
```

### Task 3: Host-qualify session identity everywhere

**Files:**
- Create: `HerdrMenubar/Remote/RemoteEndpoint.swift`
- Create: `HerdrMenubarTests/RemoteEndpointTests.swift`
- Modify: `HerdrMenubar/Herdr/SessionDiscovery.swift`
- Modify: `HerdrMenubar/Notifications/NotificationModels.swift`
- Modify: `HerdrMenubar/Notifications/NativeNotificationService.swift`
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: identity fixtures and expectations across `HerdrMenubarTests`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write duplicate-identity and payload-v2 RED tests**

Prove these distinct values coexist in sets/dictionaries and route separately:

```swift
let endpointA = RemoteEndpointID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
let endpointB = RemoteEndpointID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)

let local = SessionID.local(.named("work"))
let remoteA = SessionID.remote(endpointID: endpointA, name: .named("work"))
let remoteB = SessionID.remote(endpointID: endpointB, name: .named("work"))
XCTAssertEqual(Set([local, remoteA, remoteB]).count, 3)
```

Add notification payload tests that round-trip remote endpoint UUID + session name + pane ID with version 2, round-trip local default/named targets with version 2, reject version 1, reject malformed UUIDs, and never encode endpoint labels or SSH targets.

Expected RED: `RemoteEndpointID`, `SessionName`, and host-qualified factories are absent.

- [ ] **Step 2: Introduce value types while preserving local call-site convenience**

Use these contracts:

```swift
struct RemoteEndpointID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: UUID
}

enum SessionName: Hashable, Codable, Sendable {
    case `default`
    case named(String)
}

enum SessionOrigin: Hashable, Codable, Sendable {
    case local
    case remote(RemoteEndpointID)
}

struct SessionID: Hashable, Codable, Sendable {
    let origin: SessionOrigin
    let name: SessionName

    static let `default` = SessionID(origin: .local, name: .default)
    static func named(_ name: String) -> SessionID {
        SessionID(origin: .local, name: .named(name))
    }
    static func remote(endpointID: RemoteEndpointID, name: SessionName) -> SessionID {
        SessionID(origin: .remote(endpointID), name: name)
    }
}
```

Extend `SessionDescriptor` with `originLabel: String?`. Its `displayName` is the local session name unchanged, or `"<friendly label> · <session name>"` for remote. Never derive identity from the friendly label.

- [ ] **Step 3: Migrate all identity switches and sort order atomically**

Replace enum pattern matches with `id.origin`/`id.name`. Local sessions sort before remote sessions; remote endpoints sort by case-folded friendly label then endpoint UUID; sessions within one origin sort default first then case-folded name with the raw name as tie-breaker. Update supervisor maps, AgentStore maps, notification coordinator maps, WezTerm focus lifecycle maps, shortcut targets, menu action tokens, and all fakes in the same commit so no unqualified route remains.

- [ ] **Step 4: Encode notification payload version 2 only**

Set `payloadVersion = 2`. Encode `origin_kind`, optional `endpoint_id`, `session_kind`, optional `session_name`, and `pane_id`. Decode only exact version 2 and strictly validate nonempty names/pane ID and UUID. Do not decode version 1; backward compatibility was explicitly declined.

- [ ] **Step 5: Run GREEN, mutation checks, and commit**

Run `SessionDiscoveryTests`, `SessionSupervisorTests`, `AgentStoreTests`, `NativeNotificationServiceTests`, `AttentionNotificationCoordinatorTests`, `WezTermFocusAdapterTests`, `GlobalShortcutControllerTests`, `StatusMenuPresentationTests`, and `MultiSessionIntegrationTests`. Temporarily remove endpoint ID from equality or payload and prove duplicate-ID tests fail, then restore it.

```bash
git add HerdrMenubar HerdrMenubarTests HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "refactor: qualify herdr sessions by origin"
```

### Task 4: Validate and persist remote endpoint configuration without credentials

**Files:**
- Create: `HerdrMenubar/Remote/RemoteEndpointStore.swift`
- Create: `HerdrMenubarTests/RemoteEndpointStoreTests.swift`
- Modify: `HerdrMenubar/Remote/RemoteEndpoint.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write endpoint validation and persistence RED tests**

Cover: stable UUID; trimmed nonempty friendly label; opaque SSH target that is nonempty, does not begin with `-`, and has no controls; duplicate labels allowed; edit preserves UUID; add defaults to disconnected; successful connect can set `wasConnected`; manual disconnect clears it; remove deletes it; deterministic order; corrupt/unknown persistence version fails closed to an empty list without contacting a host.

Assert serialized defaults contain only `version`, `id`, `label`, `sshTarget`, and `wasConnected`. Search the serialized bytes for absence of `password`, `privateKey`, `resolvedHost`, `socketPath`, and pane data.

- [ ] **Step 2: Add the endpoint model and categorical status**

```swift
struct RemoteEndpoint: Identifiable, Codable, Equatable, Sendable {
    let id: RemoteEndpointID
    var label: String
    var sshTarget: String
    var wasConnected: Bool
}

enum RemoteEndpointStatus: Equatable, Sendable {
    case disconnected
    case testing
    case connecting
    case connected(sessionCount: Int)
    case noSessions
    case reconnecting
    case failed(RemoteFailureCategory)
}

enum RemoteFailureCategory: String, Codable, Equatable, Sendable {
    case authentication, hostTrust, forwarding, herdrUnavailable, invalidConfiguration, protocolMismatch
}

enum RemoteOperationError: Equatable, Sendable {
    case markerCleanupFailed
    case operationCancelled
}
```

Keep raw stderr/paths out of these types. Put validation in throwing initializers/update methods so UI and persistence share one rule.
`RemoteFailureCategory` describes endpoint connectivity only. `RemoteOperationError` is a separate,
controller-owned, ephemeral UI error and is never persisted or folded into
`RemoteEndpointStatus.failed`; present `markerCleanupFailed` as “Couldn’t safely finish focusing the
remote session. The connection was left open.” and keep the underlying error private.

- [ ] **Step 3: Add versioned persistence**

Create a `@MainActor` observable `RemoteEndpointStore` backed by injected `UserDefaults` and a single namespaced key. Encode a private envelope with exact version 1 and `[RemoteEndpoint]`. Save after validated add/edit/remove/intent changes. Load atomically; malformed envelopes yield `[]` plus a generic in-memory error state, never partial endpoints.

- [ ] **Step 4: Run GREEN and commit**

Run `RemoteEndpointTests` and `RemoteEndpointStoreTests`; inspect defaults payload manually in the test. Then:

```bash
git add HerdrMenubar/Remote/RemoteEndpoint.swift HerdrMenubar/Remote/RemoteEndpointStore.swift HerdrMenubarTests/RemoteEndpointTests.swift HerdrMenubarTests/RemoteEndpointStoreTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: persist remote herdr endpoints"
```

### Task 5: Build bounded SSH discovery and strict untrusted-data parsing

**Files:**
- Create: `HerdrMenubar/Remote/SSHInvocation.swift`
- Create: `HerdrMenubar/Remote/SSHDiscoveryClient.swift`
- Create: `HerdrMenubarTests/SSHInvocationTests.swift`
- Create: `HerdrMenubarTests/SSHDiscoveryClientTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write exact-argv and parser RED tests**

Assert one-shot argv contains the complete policy from the design, including `ClearAllForwardings=yes`, disabled multiplexing/backgrounding, and the SSH target as one final opaque argv item before the fixed remote Herdr argv. Assert no invocation uses `/bin/sh`, `zsh`, `-c`, string interpolation, TCP forwarding, or disabled host-key checking.

Add a local-only `/usr/bin/ssh -G <opaque-target>` preflight. Feed it bounded synthetic effective
configuration and prove any `localforward`, `remoteforward`, or `dynamicforward` directive returns
`.invalidConfiguration`; safe configuration returns an opaque approval. Assert the parser retains only
those categorical booleans and never retains/logs expanded host, user, address, identity, proxy,
control-path, or other values. Timeout, overflow, nonzero exit, and malformed output fail closed. In
controller-facing tests, an unsafe alias must launch neither discovery nor tunnel child and must create
no Unix or TCP listener.

Test strict decoding of version/schema/session outputs, unknown-field tolerance, unique running sessions, absolute paths, 64-session cap, UTF-8 byte limits, `%`/`$`/colon/control rejection, output caps, nonzero exit, timeout, cancellation, and categorical stderr mapping without retaining raw text.

Expected RED: the SSH invocation and discovery types are absent.

- [ ] **Step 2: Add exact invocation contracts**

```swift
struct SSHDiscoverySnapshot: Equatable, Sendable {
    let remoteVersion: String
    let protocolVersion: String
    let sessions: [RemoteHerdrSession]
}

struct RemoteHerdrSession: Equatable, Sendable {
    let name: SessionName
    let socketPath: String
}

struct ValidatedSSHConfiguration: Equatable, Sendable {
    let endpointID: RemoteEndpointID
    fileprivate let targetFingerprint: Data
    fileprivate let launchNonce: UUID
}

protocol SSHConfigurationPreflighting: Sendable {
    func validate(
        endpoint: RemoteEndpoint
    ) async -> Result<ValidatedSSHConfiguration, RemoteFailureCategory>
}

protocol SSHDiscovering: Sendable {
    func test(endpoint: RemoteEndpoint) async -> Result<SSHDiscoverySnapshot, RemoteFailureCategory>
    func discover(endpoint: RemoteEndpoint) async throws -> SSHDiscoverySnapshot
}
```

Create `SSHInvocation` as `[String]` construction only. The preflight runs `/usr/bin/ssh -G` with the
opaque target as one argv item, is bounded like every other operation, and performs no network
contact. It scans only normalized directive names/forward presence, discards all expanded values, and
returns a single-launch approval bound to the endpoint UUID plus a non-reversible digest of its exact
SSH target and a fresh nonce. Discovery always uses `ClearAllForwardings=yes`, so it does not retain or
require the approval. A tunnel launch rejects a missing/mismatched approval and consumes it only as a
local argument while constructing that one child; no manager/runtime/tunnel field stores it after
launch. Use `/usr/bin/ssh` and
`BoundedProcessRunning` with 20-second deadline, 1 MiB stdout, and 256 KiB stderr. Run the three fixed
remote commands independently and combine their sanitized parsed result. No remote binary path
fallback is permitted.

- [ ] **Step 3: Parse and validate before publishing**

Decode JSON into private `Decodable` wire structs, validate into domain structs, then discard wire data. Confirm the installed schema contains every required public method/event and the exact subscription capability before returning success. A version difference is allowed only when live/schema capabilities match; a missing capability maps to `.protocolMismatch`.

Classify auth, host-trust, forwarding, Herdr/PATH, invalid configuration, and protocol mismatch with bounded internal diagnostics logged `.private`; expose only `RemoteFailureCategory` to observable state. A valid empty session list is successful discovery and maps to `.noSessions`, not a failure.

- [ ] **Step 4: Run GREEN, overflow stress, and commit**

Run both new suites plus `BoundedProcessRunnerTests`. Stress timeout/cancellation/output-overflow cases 50 iterations and assert all fake PIDs are reaped.

```bash
git add HerdrMenubar/Remote/SSHInvocation.swift HerdrMenubar/Remote/SSHDiscoveryClient.swift HerdrMenubarTests/SSHInvocationTests.swift HerdrMenubarTests/SSHDiscoveryClientTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: discover remote herdr sessions over ssh"
```

### Task 6: Own long-lived StreamLocal tunnels and crash-orphan cleanup

**Files:**
- Create: `HerdrMenubar/Remote/TunnelWorkspace.swift`
- Create: `HerdrMenubar/Remote/ManagedSSHTunnel.swift`
- Create: `HerdrMenubar/Remote/SSHTunnelManifest.swift`
- Create: `HerdrMenubarTests/TunnelWorkspaceTests.swift`
- Create: `HerdrMenubarTests/ManagedSSHTunnelTests.swift`
- Create: `HerdrMenubarTests/SSHTunnelManifestTests.swift`
- Modify: `HerdrMenubar/System/BoundedProcessRunner.swift`
- Modify: `HerdrMenubarTests/BoundedProcessRunnerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write lifecycle, permission, and orphan RED tests**

Using executable fixtures and a fake process/socket filesystem, cover the complete exact argv below,
rejection of a missing/mismatched `ValidatedSSHConfiguration`, short per-run private root, owner-only
socket, `ExitOnForwardFailure`, listener-plus-public-ping readiness, manager-owned stable local path
across two replacement tunnels, independent paths for duplicate session names on different endpoints,
early child exit, timeout, stderr overflow, cancellation, TERM-ignore→KILL→reap, exit-event delivery,
event-stream finish on stop, stop idempotence, concurrent stop join, no PID-only kill, and unexpected
replacement-file refusal. Assert the invocation creates no TCP listener.

Model effective config as a mutable fake. Start Connect while safe, then change it to include a
configured forward before (a) the first session tunnel launch and (b) a replacement launch. Each
fresh preflight must reject the launch with no child/listener while unrelated healthy tunnels remain
running. Restore safe config, retry, and prove the replacement uses the same manager-owned stable
socket slot with a new one-launch approval.

For manifest cleanup, prove only same-UID/versioned records under the validated app runtime root are considered; `ssh -S <controlPath> -O check <target>` must succeed before `-O exit`; mismatched owner/type/path/target stays untouched and yields a categorical diagnostic.

Use one stable short parent `/tmp/herdr-menubar-<numeric uid>` with mode `0700`. `TunnelWorkspace` creates random owner-only per-run/per-session slot directories whose names contain no endpoint/session label and returns a `StableTunnelSlot` containing the manager-owned directory identity plus stable local socket URL. A tunnel instance owns only its current child, listener entry, control socket, and manifest inside that slot; `stop()` removes those artifacts but never the slot directory. A replacement tunnel receives the same slot/socket URL. Final endpoint teardown asks `TunnelWorkspace` to validate path/device/inode/owner/mode/emptiness and remove the slot exactly once.

Each 0600 manifest has exact version, endpoint UUID, random tunnel UUID, opaque SSH target, standardized control/local socket paths, and recorded device/inode/type metadata; it contains no credentials, resolved host, session label, or pane state. On a later launch, scan only direct children of the validated stable parent, never a recursive or prefix-expanded path.

- [ ] **Step 2: Extract a reusable owned long-lived process seam**

Add without weakening `BoundedProcessRunner`:

```swift
protocol OwnedProcessLaunching: Sendable {
    func launch(_ invocation: OwnedProcessInvocation) async throws -> any OwnedProcess
}

enum OwnedProcessFailure: Error, Equatable, Sendable {
    case launchFailed
    case stdoutLimitExceeded
    case stderrLimitExceeded
    case cancelled
}

enum OwnedProcessTermination: Equatable, Sendable {
    case exited(status: Int32)
    case terminated(signal: Int32, forced: Bool)
    case failed(OwnedProcessFailure)
}

struct OwnedProcessTerminationPolicy: Equatable, Sendable {
    let termGrace: Duration
    let killGrace: Duration

    static let tunnel = OwnedProcessTerminationPolicy(
        termGrace: .seconds(2),
        killGrace: .seconds(2)
    )
}

protocol OwnedProcess: Sendable {
    var processIdentifier: Int32 { get async }
    func waitForTermination() async -> OwnedProcessTermination
    func terminateAndWait(policy: OwnedProcessTerminationPolicy) async -> OwnedProcessTermination
}

enum ProcessOutputMode: Equatable, Sendable {
    case discard
    case bounded(Int)
}

struct OwnedProcessInvocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let stdoutMode: ProcessOutputMode
    let stderrLimit: Int
}
```

Reuse the existing POSIX spawn/waitpid identity ownership: one actor retains the unreaped child, never suspends between a `waitpid(WNOHANG)` identity check and signal, concurrently drains bounded output, and resumes waiters exactly once. `BoundedProcessRunner` and `ManagedSSHTunnel` share this primitive rather than adding Foundation `Process` or raw check-then-kill logic.

The handle owns one stdout reader task, one stderr reader task, one waitpid monitor, and one multi-waiter termination state. The first exit/overflow/cancel/explicit-stop claimant selects the terminal reason under actor ownership. Output overflow immediately starts the same TERM→policy grace→SIGKILL→reap path; terminal completion is not published until both reader tasks and waitpid monitor finish. Any number of concurrent `waitForTermination`/`terminateAndWait` callers receive the same immutable result. `launch` throws `.launchFailed` before returning a handle; no hidden callback or single-waiter latch is permitted.

- [ ] **Step 3: Implement the tunnel state machine**

`ManagedSSHTunnel.start()` validates and uses the supplied `StableTunnelSlot`; it does not create or
remove the slot directory. It creates only its per-instance 0600 manifest, control socket, listener,
and child-process artifacts inside that slot, validates path byte lengths, launches one owned SSH
master with `ControlPersist=no`, and waits boundedly for both secure socket metadata and a public
`ping` supplied through an injected probe. Publish `socketURL` only after both pass.

Expose only the lifecycle the manager needs:

```swift
enum ManagedSSHTunnelEvent: Equatable, Sendable {
    case exited(RemoteFailureCategory)
}

protocol ManagedSSHTunneling: Sendable {
    func events() async -> AsyncStream<ManagedSSHTunnelEvent>
    func start() async throws -> URL
    func stop() async
}

struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let ownerUID: UInt32
    let mode: UInt16
}

struct StableTunnelSlot: Equatable, Sendable {
    let directoryURL: URL
    let localSocketURL: URL
    let identity: FileIdentity
}

protocol ManagedSSHTunnelCreating: Sendable {
    func makeTunnel(
        endpoint: RemoteEndpoint,
        session: RemoteHerdrSession,
        slot: StableTunnelSlot,
        approvedBy: ValidatedSSHConfiguration
    ) async throws -> any ManagedSSHTunneling
}
```

Construct the tunnel as this exact direct argv sequence, with generated paths validated to contain no
OpenSSH expansion tokens and the target kept as one final opaque element:

```text
/usr/bin/ssh
-N -T -n
-o BatchMode=yes
-o StrictHostKeyChecking=yes
-o ConnectTimeout=10
-o ConnectionAttempts=1
-o ExitOnForwardFailure=yes
-o ForwardAgent=no
-o ForwardX11=no
-o PermitLocalCommand=no
-o ControlMaster=yes
-o ControlPath=<validated unique control socket>
-o ControlPersist=no
-o ForkAfterAuthentication=no
-o StreamLocalBindMask=0177
-o StreamLocalBindUnlink=no
-o ServerAliveInterval=15
-o ServerAliveCountMax=2
-L <validated local Unix socket>:<validated remote Unix socket>
<opaque SSH target>
```

Do not add `ClearAllForwardings=yes` to this invocation because it would clear the required `-L`.
Safety instead comes from the matching one-launch `ValidatedSSHConfiguration`, which proves the
immediately preceding local `ssh -G` preflight found no configured local, remote, or dynamic forwards.
A missing, reused, or target-mismatched approval fails before launching SSH or creating listener
artifacts. The factory uses the approval only to construct/launch that exact child and does not retain
it after `start()` returns.

`stop()` invalidates generation first, closes probe/client handles, sends verified control exit when available, terminates and awaits the retained exact child, verifies no listener, and removes only registered same-owner artifacts. Repeated/concurrent stops await one shared barrier. Never remove a socket based only on path text and never signal a historical PID.

- [ ] **Step 4: Run GREEN, TSan, and commit**

Run `TunnelWorkspaceTests`, `ManagedSSHTunnelTests`, `SSHTunnelManifestTests`, and
`BoundedProcessRunnerTests`; stress start/stop/cancel/overflow 100 iterations; run all four suites
with Thread Sanitizer. Verify fixture PIDs and temp roots are absent afterward.

```bash
git add HerdrMenubar/Remote/TunnelWorkspace.swift HerdrMenubar/Remote/ManagedSSHTunnel.swift HerdrMenubar/Remote/SSHTunnelManifest.swift HerdrMenubar/System/BoundedProcessRunner.swift HerdrMenubarTests/TunnelWorkspaceTests.swift HerdrMenubarTests/ManagedSSHTunnelTests.swift HerdrMenubarTests/SSHTunnelManifestTests.swift HerdrMenubarTests/BoundedProcessRunnerTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: own remote herdr ssh tunnels"
```

### Task 7: Publish cached remote descriptors without putting network work in supervisor scans

**Files:**
- Create: `HerdrMenubar/Remote/RemoteSessionRegistry.swift`
- Create: `HerdrMenubar/Remote/CompositeSessionDiscovery.swift`
- Create: `HerdrMenubarTests/RemoteSessionRegistryTests.swift`
- Create: `HerdrMenubarTests/CompositeSessionDiscoveryTests.swift`
- Modify: `HerdrMenubar/Herdr/SessionSupervisor.swift`
- Modify: `HerdrMenubarTests/SessionSupervisorTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write cache isolation and stable-path RED tests**

Prove: local discovery returns while a fake remote network call is blocked; registry reads are actor-local and bounded; remote descriptors carry endpoint-qualified IDs/friendly labels; successful publish atomically replaces one endpoint snapshot; failed refresh retains its prior snapshot; explicit clear removes only one endpoint; duplicate local/remote names remain distinct; re-publishing one session with the same logical identity requires the same current-run socket URL.

Expected RED: registry and composite discovery are absent.

- [ ] **Step 2: Implement registry and composite discovery**

```swift
actor RemoteSessionRegistry {
    private var descriptorsByEndpoint: [RemoteEndpointID: [SessionDescriptor]] = [:]

    func replace(endpointID: RemoteEndpointID, with descriptors: [SessionDescriptor])
    func clear(endpointID: RemoteEndpointID)
    func snapshot() -> [SessionDescriptor]
}

protocol SessionDiscoveryReconciling: Sendable {
    func reconcileDiscovery() async -> ReconciliationStatus
}

struct CompositeSessionDiscovery: SessionDiscovering {
    let local: any SessionDiscovering
    let remote: RemoteSessionRegistry

    func discover() async throws -> [SessionDescriptor] {
        let localDescriptors = try await local.discover()
        return localDescriptors + await remote.snapshot()
    }
}
```

Sort remote snapshots deterministically but preserve local-first ordering. Registry mutation is the only publication path; it receives already-started tunnel URLs and never performs SSH/network work itself.

Make `SessionSupervisor` conform to `SessionDiscoveryReconciling` by exposing its existing coalesced reconciliation worker as `reconcileDiscovery()`. The returned status is `.applied` only after `CompositeSessionDiscovery` has been read and `apply(descriptors:)` has finished. Cancellation, discovery failure, and stopped lifecycle return their existing non-applied statuses. Remote managers inject this seam: after removing a failed tunnel descriptor they must await `.applied` before any republish, which deterministically enters supervisor grace; after a ready republish they await another `.applied` for prompt recovery. Label-only updates use the same bounded/coalesced call for immediate presentation refresh. If absence reconciliation fails, retain the omission, back off, and retry reconciliation rather than republishing early.

- [ ] **Step 3: Run GREEN and commit**

Run the two new suites plus `SessionDiscoveryTests` and `SessionSupervisorTests`. Block a fake SSH discovery forever and prove 100 composite scans still return local + cached data. Gate a failed-tunnel restart before absence reconciliation and prove the descriptor cannot republish; release reconciliation, prove `.unavailable`/grace first, then allow same-path ready republish and exact retry.

```bash
git add HerdrMenubar/Remote/RemoteSessionRegistry.swift HerdrMenubar/Remote/CompositeSessionDiscovery.swift HerdrMenubar/Herdr/SessionSupervisor.swift HerdrMenubarTests/RemoteSessionRegistryTests.swift HerdrMenubarTests/CompositeSessionDiscoveryTests.swift HerdrMenubarTests/SessionSupervisorTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: compose cached remote sessions"
```

### Task 8: Reconcile one endpoint's sessions independently

**Files:**
- Create: `HerdrMenubar/Remote/RemoteEndpointManager.swift`
- Create: `HerdrMenubarTests/RemoteEndpointManagerTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write endpoint-manager RED tests with deterministic clocks**

Cover explicit start only; 15-second successful reconciliation cadence; bounded exponential backoff with deterministic jitter injection; one tunnel per running session; stable tunnel reuse; new-session start; successful disappearance stop/removal; failed discovery retaining healthy tunnels and cache; one tunnel failure restarting only that session; friendly-label update republishing descriptors without tunnel/client recreation; no-session categorical state; stale discovery/tunnel callback rejection; connect/stop overlap; stop invalidation before cancel; concurrent stop barrier; and no registry publication until each tunnel passes secure socket + ping readiness. Require the manager to acquire and retain each tunnel event stream before `start()`, keep that exact terminal monitor alive through reversible disconnect/app-stop quiescence, and cancel/await it only after tunnel disposal or replacement.

Add two deterministic rollback cases: block marker cleanup, exit the retained tunnel, then fail cleanup
during (a) manual disconnect and (b) application-stop preparation. Rollback must observe the recorded
termination, must not restore the dead descriptor as healthy, must publish/await an absent snapshot,
and must either start the exact session recovery path or finish terminal teardown as appropriate. No
terminal event may be lost between quiescence and rollback.

Use a mutable preflight fake to prove a safe controller Connect followed by an unsafe effective-config
change blocks both the first tunnel and a later replacement before any child/listener exists. Restore
safe config and prove exact-session recovery uses the same stable slot; another healthy session and
endpoint remain unchanged.

- [ ] **Step 2: Implement the actor-owned generation model**

Use:

```swift
actor RemoteEndpointManager {
    struct Runtime {
        let session: RemoteHerdrSession
        let tunnel: any ManagedSSHTunneling
        let generation: UInt64
        let slot: StableTunnelSlot
        var terminalMonitorTask: Task<Void, Never>?
        var restartTask: Task<Void, Never>?
    }

    struct DisconnectContext {
        let token: RemoteEndpointDisconnectToken
        var terminatedSessions: Set<SessionName>
    }

    private var generation: UInt64 = 0
    private var runtimes: [SessionName: Runtime] = [:]
    private var loopTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
}
```

Require `RemoteEndpointManager` initialization with endpoint, `SSHConfigurationPreflighting`,
discovery client, tunnel factory, `TunnelWorkspace`, registry, `SessionDiscoveryReconciling`,
sleeper/clock, and deterministic backoff jitter. Immediately before every initial, newly discovered,
or replacement tunnel launch, await a fresh preflight and pass its approval only to that
`makeTunnel`/`start` operation. Never retain approval in `Runtime`. A preflight failure publishes the
categorical endpoint/session configuration failure, launches no child/listener, preserves unrelated
healthy runtimes, and enters bounded retry. A later safe preflight recovers through the same stable
slot. It does not construct or look up a global supervisor.

Define the controller's complete fakeable boundary here rather than exposing the concrete actor:

```swift
protocol RemoteEndpointManaging: Sendable {
    func events() async -> AsyncStream<RemoteEndpointStatus>
    func connect() async throws -> RemoteEndpointStatus
    func updateLabel(_ label: String) async
    func retry(session: SessionName) async
    func beginDisconnect() async -> RemoteEndpointDisconnectToken
    func cancelDisconnect(_ token: RemoteEndpointDisconnectToken) async
    func withdrawDescriptors(_ token: RemoteEndpointDisconnectToken) async
    func finishDisconnect(_ token: RemoteEndpointDisconnectToken) async
}

protocol RemoteEndpointManagerCreating: Sendable {
    func makeManager(endpoint: RemoteEndpoint) -> any RemoteEndpointManaging
}
```

`events()` is acquired and its terminal monitor retained before `connect()`. The factory owns the
shared discovery/tunnel/workspace/registry/reconciliation dependencies and creates one actor per
endpoint UUID. Normal stop/replacement cancels and awaits the monitor only after its exact tunnel has
been stopped and reaped; reversible quiescence does not cancel it.

Each successful discovery diffs the authoritative session-name set, starts missing tunnels, preserves unchanged ones, stops removed ones, then atomically replaces the endpoint registry snapshot with descriptors for ready tunnels. A discovery failure updates only categorical endpoint status and retry schedule; it does not clear cache or healthy tunnels.

For each ready tunnel, attach/store its terminal monitor before `start()` can publish the descriptor.
On `.exited` in the normal connected state, revalidate endpoint + runtime generations, atomically
replace the registry snapshot without that one session, await the explicit absent-snapshot
reconciliation defined in Task 7, stop/reap the old tunnel, cancel/await its monitor, and create one
endpoint/session-owned restart task using only that session's backoff. Recreate the tunnel with the
same manager-owned `slot` for this app-run session identity, publish only after socket ownership +
public ping readiness, request/await present-snapshot reconciliation, and let the supervisor retry
the returning runtime inside grace.

On `.exited` while a disconnect or terminal-stop token is quiescing, the same monitor records the
session in that token's `terminatedSessions` and reaps the exact child, but suppresses registry
publication and restart until the reversible operation resolves. `cancelDisconnect`/terminal-stop
rollback must consult that recorded set: live runtimes retain their descriptor and monitor; terminated
runtimes are atomically unpublished, await an applied absent snapshot, cancel/await the completed
monitor, and enter the exact per-session restart path under the fresh generation. A dead runtime can
never be republished merely because cleanup rolled back. Successful removal/terminal finish stops
remaining tunnels first, then cancels/awaits every monitor and restart task, and only final removal
releases the slot through `TunnelWorkspace`.

Split terminal shutdown into two explicit phases so clients are gone before forwarded sockets:

```swift
struct RemoteEndpointDisconnectToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

func beginDisconnect() async -> RemoteEndpointDisconnectToken
func cancelDisconnect(_ token: RemoteEndpointDisconnectToken) async
func withdrawDescriptors(_ token: RemoteEndpointDisconnectToken) async
func finishDisconnect(_ token: RemoteEndpointDisconnectToken) async
```

`beginDisconnect()` first performs an actor-synchronous transition that invalidates the publication/
restart generation, creates a `DisconnectContext`, and captures exact tunnel/monitor/slot ownership
under its unforgeable token. It then cancels and awaits discovery/retry producer work before returning
that token. It deliberately keeps every terminal monitor alive and does not change the registry,
clients, or tunnels. This keeps the supervisor runtime `isPresent` while marker cleanup runs even if a
periodic scan occurs, while still recording a tunnel death.
`cancelDisconnect(token)` is allowed only before withdrawal; it assigns a fresh generation, restores
discovery/retry ownership for live runtimes, and reconciles every recorded termination through the
absent-snapshot/restart sequence above. It never blindly republishes the pre-quiescence cache. After
marker drain, `withdrawDescriptors(token)` clears only that endpoint's registry cache, marks the token
irreversible, and rejects stale publication. After the caller removes supervisor clients,
`finishDisconnect` accepts only the same token, drains discovery/restart work, stops/awaits every
captured tunnel, cancels/awaits its terminal monitor, releases validated stable slots, publishes
disconnected, and forms one shared completion barrier for repeated callers.

Expose `func updateLabel(_ label: String) async` for a connected endpoint. It changes presentation metadata only, atomically republishes the current descriptors with the same endpoint UUID, session IDs, socket URLs, clients, and tunnels, then awaits `reconcileDiscovery() == .applied` before returning so AgentStore receives the new descriptor immediately. The manager has no live SSH-target mutation API.

Expose `func retry(session: SessionName) async`. It cancels/replaces only that session's backoff/restart task and attempts discovery/tunnel recovery without resetting another session or endpoint.

- [ ] **Step 3: Run GREEN, stress lifecycle, and commit**

Run `RemoteEndpointManagerTests` 100 iterations for the overlap/removal/restart subset and once under TSan. Assert every fake tunnel has exact start/stop counts and every waiter finishes.

```bash
git add HerdrMenubar/Remote/RemoteEndpointManager.swift HerdrMenubarTests/RemoteEndpointManagerTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: reconcile remote endpoint sessions"
```

### Task 9: Own all endpoints, explicit intent, targeted removal, and retry

**Files:**
- Create: `HerdrMenubar/Remote/RemoteSessionsController.swift`
- Create: `HerdrMenubarTests/RemoteSessionsControllerTests.swift`
- Modify: `HerdrMenubar/Herdr/SessionSupervisor.swift`
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/System/WezTermFocusAdapter.swift`
- Modify: `HerdrMenubarTests/SessionSupervisorTests.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`
- Modify: `HerdrMenubarTests/WezTermFocusAdapterTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write controller and supervisor RED tests**

Test: adding/editing never contacts a host; Test Connection performs the bounded local SSH-config
preflight followed by one bounded discovery without saving connected intent or publishing sessions;
Connect performs the same preflight before creating a manager and sets `wasConnected` only after
successful connection. An unsafe effective Local/Remote/DynamicForward returns
`.invalidConfiguration`, launches no discovery/tunnel child, creates no listener, and leaves intent
false. Disconnect clears intent, invalidates callbacks, immediately removes only that endpoint's
supervisor runtimes without ten-second grace, and awaits tunnels; Remove performs disconnect then
deletes; simultaneous endpoints do not block each other; retry targets one endpoint/session;
transient tunnel loss still enters existing ten-second grace through normal discovery absence;
endpoint A failure cannot change endpoint B/local state. Gate a real/fake WezTerm focus after
`client.window_title.set`; trigger manual disconnect; prove cancellation is observed,
`client.window_title.clear` completes, then supervisor client stop completes, and only then may the
first tunnel stop begin. Add the same ordering assertion for application shutdown.

At every manual-disconnect await boundary, cancel the initiating UI task. Before the commit point,
assert the controller-owned operation rolls marker/manager preparation back and remains connected.
Immediately before/after descriptor withdrawal, during supervisor removal, and during tunnel stop,
assert exactly one controller-owned operation continues cancellation-independently through client
removal, tunnel/slot cleanup, and intent clearing; repeated disconnect/remove callers join the same
barrier. Close/stop the Remote Hosts window during each case and prove its canceled wrapper is still
drained without canceling the controller operation. Add a controller stop case that awaits all owned
endpoint operations.

Expected RED: controller, endpoint-scoped immediate removal, and targeted retry APIs are absent.

- [ ] **Step 2: Add exact supervisor control APIs**

Extend `SessionSupervising` with:

```swift
func removeSessions(origin: SessionOrigin) async
func retryUnavailable(sessionIDs: Set<SessionID>) async
```

`SessionSupervisor.removeSessions(origin:)` invalidates/removes matching ownership before awaits, cancels/awaits their event/grace/client tasks, emits `.removed` once per ID, and leaves all other runtimes untouched. `retryUnavailable(sessionIDs:)` preserves the existing generation/coalescing/cancellation guarantees while claiming only the supplied IDs. Replace the public zero-argument retry API and its runtime dependency with this targeted API; no retry-all UI or compatibility wrapper remains.

Add explicit store/focuser-owned drain seams:

```swift
@MainActor
protocol SessionRemovalPreparing: AnyObject {
    func prepareForRemoval(origin: SessionOrigin) async throws
    func cancelRemovalPreparation(origin: SessionOrigin)
    func finishRemoval(origin: SessionOrigin)
}

struct AgentStoreStopPreparation: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

@MainActor
protocol WezTermSessionFocusing: Sendable {
    func focusAttachedClient(sessionID: SessionID) async throws
    func drain(origin: SessionOrigin) async throws
    func drainAll() async throws
    func forget(sessionID: SessionID)
}
```

`AgentStore` conforms to `SessionRemovalPreparing`. Replace the single opaque selection handle with an ID-keyed `OwnedSelectionWork` registry that retains every current and predecessor task with its exact `SessionID` until that task completes; keep the existing latest-wins serialization, but never lose predecessor ownership when installing a successor. `prepareForRemoval` inserts the origin into a draining set so new matching selections are rejected, invalidates/cancels every matching owned task, awaits every matching task (including predecessors), then calls `wezTermFocuser.drain(origin:)`. Do not call `forget` first. `cancelRemovalPreparation` removes the rejection barrier after a failed marker drain; `finishRemoval` removes it only after supervisor removal completes. A pending notification target has no marker and remains for the subsequent `.removed` event to clear with the existing unavailable message.

`LiveWezTermFocusAdapter` separately owns an ID-keyed registry of every active marker operation and its session plus the existing `pendingCleanup` set. Register before resolving/setting a marker; complete only after marker state is cleared or recorded pending. `drain(origin:)` awaits all matching active operations and then retries `clearClientWindowTitle` for every matching pending-cleanup session through its still-current lifecycle; it succeeds only when both collections have no matching entry. `drainAll` applies the same rule to every origin. Both are bounded by the existing per-clear budget and throw `.markerCleanupFailed` rather than discarding pending state. `forget` is legal only after a successful drain or an authoritative removal that never installed a marker.

`AgentStore.stop()` rejects all new selections, cancels/awaits the complete owned-selection registry, calls `wezTermFocuser.drainAll()`, and only then calls `supervisor.stop()`. Focus-drain failure is surfaced to `ApplicationRuntime` as a blocked normal shutdown; it must not be silently converted into client/tunnel teardown. Tests cover a completed earlier selection that left `pendingCleanup`, a remote predecessor hidden behind a local successor, and a newly attempted remote selection during removal preparation.

Implement that normal-stop path as `prepareStop() async throws -> AgentStoreStopPreparation`, `cancelStopPreparation(_:)`, and `finishStop(_:) async`. Preparation rejects new selections and drains all selection/marker ownership without clearing presentation or stopping the supervisor. Cancel re-enables selections if preparation fails. Finish accepts only the matching token, performs the existing event/notification/task drain, and stops the supervisor. Change the convenience to `stop() async throws`; it prepares then finishes for tests/non-app callers and never hides a drain failure. Update all fakes/call sites in this task.

- [ ] **Step 3: Implement the observable controller**

Make `RemoteSessionsController` `@Observable @MainActor`; inject endpoint store,
`SSHConfigurationPreflighting`, discovery client, manager factory, supervisor,
`SessionRemovalPreparing`, registry, and stale-manifest cleaner. Maintain manager/task
ownership by stable endpoint UUID. In addition to endpoint connection status, expose a separate
`operationErrors: [RemoteEndpointID: RemoteOperationError]` map for safe, ephemeral action failures;
never persist it or convert it into a connectivity failure. Every async callback carries a
per-endpoint lifecycle token checked after each await before observable mutation. Editing a connected
endpoint permits label-only changes: persist the label, await `manager.updateLabel`, and trigger cached
reconciliation; it must produce no SSH call. Reject an SSH-target change while connected. While
disconnected, validate and persist a target change without contacting the old or new target.

Both Test Connection and Connect first await the local-only preflight and discard its approval after
the initial gate; no remote-capable call occurs before that gate succeeds. Test Connection then makes
one discovery call, whose argv independently uses `ClearAllForwardings=yes`. Connect creates the
manager only after the gate. The manager performs its own fresh preflight immediately before each
tunnel child launch and does not reuse the controller's approval. An approval is single-launch and
invalid after any endpoint target/config change.

Expose `func retry(sessionID: SessionID) async`. Reject local IDs. For a remote ID, look up the exact endpoint UUID and session name, reset only that manager/session backoff, and then call `supervisor.retryUnavailable(sessionIDs: [sessionID])`; revalidate endpoint lifecycle between awaits.

The controller owns one `EndpointDisconnectOperation` per endpoint, retained in an operation registry;
public Disconnect/Remove calls and repeated callers await that same task. The task is unstructured with
respect to the initiating UI task and therefore is not implicitly canceled with it. A caller
cancellation handler records a request on the owned state machine but still joins its completion
barrier; controller/window stop cancels wrappers and awaits the operation registry.

The operation has an actor-serialized reversible `.preparing` phase and irreversible `.committed`
phase. In `.preparing`, execute `await manager.beginDisconnect()` and
`try await removalPreparer.prepareForRemoval(origin:)`. Check a recorded cancellation request before
commit; if set, call `removalPreparer.cancelRemovalPreparation(origin:)` and
`manager.cancelDisconnect(token)`, then finish as canceled while still connected. The atomic commit
transition occurs immediately before calling `manager.withdrawDescriptors(token)`. From that point,
caller cancellation is only observed for diagnostics and cannot cancel or early-return the owned
task. It must continue cancellation-independently through `withdrawDescriptors` →
`supervisor.removeSessions(origin:)` → `removalPreparer.finishRemoval(origin:)` →
`manager.finishDisconnect(token)` → persist `wasConnected = false`. Only after that final persistence
does the shared barrier complete and leave the operation registry. Remove waits for this same barrier
before deleting the endpoint.

Thus producer callbacks are stale first while the descriptor remains present, every predecessor/
active/pending marker cleanup drains while the client and forward are alive, the cache withdraws,
Herdr clients stop next, and tunnels/slots stop last. Force a periodic supervisor scan between begin
and marker clear in the regression test and require clear still succeeds. If preparation fails, call
the same rollback methods, leave intent/client/tunnel connected, set
`operationErrors[endpointID] = .markerCleanupFailed`, and do not commit or withdraw. Connect/test/
disconnect return categorical outcomes. A schema-valid discovery is a successful connection even when
it reports zero running sessions, so it sets `wasConnected = true` and presents `.noSessions`;
authentication, transport, or protocol failure does not set intent. Raw SSH error detail is logged
`.private` only.

For whole-app shutdown expose:

```swift
struct RemoteSessionsStopToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

func beginTerminalStop() -> RemoteSessionsStopToken
func cancelTerminalStop(_ token: RemoteSessionsStopToken) async
func finishTerminalStopAfterSessionClients(_ token: RemoteSessionsStopToken) async
```

Begin invalidates all endpoint/controller publication generations and cancels discovery/retry/UI
producer work without withdrawing descriptors or stopping tunnels. It leaves every manager-owned
terminal monitor alive under the terminal token so a tunnel exit during blocked marker cleanup is
recorded. `cancelTerminalStop` is accepted only before client teardown; it assigns fresh endpoint/
controller generations, restores discovery/retry ownership, and asks each manager to reconcile its
recorded quiescent terminations through absence/restart rather than blindly preserving cached
descriptors. ApplicationRuntime prepares/stops AgentStore while tunnels stay live. Finish first awaits
all controller-owned endpoint operations, then stops/awaits every tunnel, cancels/awaits terminal
monitors, clears the registry, and rejects all late callbacks. Repeated callers share one tokenized
barrier.

- [ ] **Step 4: Run GREEN and commit**

Run `RemoteSessionsControllerTests`, `RemoteEndpointManagerTests`, `SessionSupervisorTests`, and `AgentStoreTests`; stress concurrent connect/disconnect/stop 100 iterations and run TSan.

```bash
git add HerdrMenubar/Remote/RemoteSessionsController.swift HerdrMenubar/Herdr/SessionSupervisor.swift HerdrMenubar/Status/AgentStore.swift HerdrMenubar/System/WezTermFocusAdapter.swift HerdrMenubarTests/RemoteSessionsControllerTests.swift HerdrMenubarTests/SessionSupervisorTests.swift HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/WezTermFocusAdapterTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: control remote herdr endpoints"
```

### Task 10: Preserve host-qualified routing through menu, notifications, shortcuts, and focus

**Files:**
- Modify: `HerdrMenubar/Status/AgentStore.swift`
- Modify: `HerdrMenubar/Menu/StatusMenuPresentation.swift`
- Modify: `HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift`
- Modify: `HerdrMenubar/System/WezTermFocusAdapter.swift`
- Modify: `HerdrMenubarTests/AgentStoreTests.swift`
- Modify: `HerdrMenubarTests/StatusMenuPresentationTests.swift`
- Modify: `HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift`
- Modify: `HerdrMenubarTests/WezTermFocusAdapterTests.swift`
- Modify: `HerdrMenubarTests/GlobalShortcutControllerTests.swift`

- [ ] **Step 1: Write exact duplicate-ID routing RED tests**

Construct local, remote A, and remote B sessions with the same session name and pane ID. Assert three distinct menu targets, independent status transitions, independent unavailable/removal state, exact supervisor focus/refresh/retry calls, exact WezTerm marker lifecycle, notification titles using friendly labels, notification-click routing, and latest-notification shortcut routing. Assert no route falls back to local/default or another endpoint when the exact remote target is absent.

Add grace tests: transient remote absence holds its exact target; reconnect selects it once; explicit endpoint disconnect/removal abandons it and publishes `"<friendly label> · <session> is unavailable"`; another endpoint connecting cannot erase that error.

- [ ] **Step 2: Update presentation and error construction**

Use `SessionDescriptor.displayName` as the only user-facing session heading and error prefix. Preserve raw `SessionID` in every `NotificationSelectionTarget`, `AgentMenuItemID`, `StatusMenuAction.select`, coordinator state key, pending target, latest target, and focuser lifecycle. Never reconstruct a session ID from a displayed string.

Add the exact action identity:

```swift
case retrySession(SessionID)
```

On every `.discoverySnapshot`, update the stored descriptor for an existing `SessionID` as well as inserting new IDs. This makes a friendly-label edit visible without recreating the `HerdrClient`; it must not clear items, connectivity, unavailable grace, or a pending target.

Keep local labels byte-for-byte unchanged. Remote headings use friendly label + session display name. Replace the single global unavailable retry action with one exact unavailable-session action carrying `StatusMenuAction.retrySession(SessionID)`; local and remote rows use the same behavior, and selecting one retries only that supervisor runtime plus, for remote identity, that manager/session backoff. Notification content and public UI never include `sshTarget`, resolved host, socket path, or raw stderr.

- [ ] **Step 3: Run GREEN, mutation checks, and commit**

Run all listed suites. Temporarily drop the endpoint UUID at one boundary each for menu, notification payload, shortcut, and focus; confirm the corresponding duplicate-ID assertion fails; restore production.

```bash
git add HerdrMenubar/Status/AgentStore.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubar/Notifications/AttentionNotificationCoordinator.swift HerdrMenubar/System/WezTermFocusAdapter.swift HerdrMenubarTests/AgentStoreTests.swift HerdrMenubarTests/StatusMenuPresentationTests.swift HerdrMenubarTests/AttentionNotificationCoordinatorTests.swift HerdrMenubarTests/WezTermFocusAdapterTests.swift HerdrMenubarTests/GlobalShortcutControllerTests.swift
git commit -m "feat: route remote sessions by endpoint"
```

### Task 11: Add the Remote Hosts management window

**Files:**
- Create: `HerdrMenubar/Remote/RemoteHostsView.swift`
- Create: `HerdrMenubar/Remote/RemoteHostsWindowController.swift`
- Create: `HerdrMenubarTests/RemoteHostsTests.swift`
- Modify: `HerdrMenubar/Menu/StatusMenuPresentation.swift`
- Modify: `HerdrMenubarTests/StatusMenuPresentationTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write presentation, hosted-view, and window RED tests**

Require one `Remote Hosts…` menu action. The window lists friendly label and safe status; Add/Edit fields are Friendly Name and SSH Config Alias; Save validates inline; Test Connection, Connect, Disconnect, and Remove map to the exact endpoint UUID; Remove requires confirmation and disconnect completion; raw SSH details never render. A connected endpoint may rename its friendly label but cannot change its SSH target until disconnected. Cover empty state, duplicate labels with distinct UUIDs, changing label without identity change, target-edit disabling while connected, in-flight disabled controls, error accessibility including the categorical reason, close/reopen reuse, and terminal stop.

- [ ] **Step 2: Add the menu action and immutable row presentation**

Add `StatusMenuAction.openRemoteHosts` immediately before `openKeyboardShortcuts`, preserving existing actions/order otherwise. Define view-facing immutable rows that contain endpoint UUID, friendly label, alias only while editing, status text, enabled actions, and categorical error text. The main status menu shows friendly session headings but does not show aliases.

- [ ] **Step 3: Implement and own one reusable window**

Follow `KeyboardShortcutSettingsWindowController`: one titled/closable non-resizable settings window, `isReleasedWhenClosed = false`, SwiftUI hosting view, no activation-policy mutation, repeated `show()` activates/orders the same window, and terminal async `stop()` closes/releases owned state, cancels/awaits its action registry, and makes future show inert.

Wire UI callbacks directly to `RemoteSessionsController`; retain returned wrapper tasks in a view
model/controller registry so close/stop cancels and awaits them rather than launching unowned `Task`
values. Disconnect/Remove wrappers only signal cancellation to the controller-owned
`EndpointDisconnectOperation`; they keep awaiting its shared barrier, including after descriptor
withdrawal. The window never owns or directly cancels the underlying disconnect state machine.

- [ ] **Step 4: Run GREEN and commit**

Run `RemoteHostsTests`, `StatusMenuPresentationTests`, and `StatusItemControllerTests`; stress close/reopen and action cancellation 50 iterations.

```bash
git add HerdrMenubar/Remote/RemoteHostsView.swift HerdrMenubar/Remote/RemoteHostsWindowController.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubarTests/RemoteHostsTests.swift HerdrMenubarTests/StatusMenuPresentationTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: manage remote herdr hosts"
```

### Task 12: Add restart consent before any remote contact

**Files:**
- Modify: `HerdrMenubar/Remote/RemoteSessionsController.swift`
- Create: `HerdrMenubar/Remote/RemoteReconnectPrompt.swift`
- Create: `HerdrMenubarTests/RemoteReconnectPromptTests.swift`
- Modify: `HerdrMenubar/App/ApplicationRuntime.swift`
- Modify: `HerdrMenubar/App/HerdrMenubarApp.swift`
- Modify: `HerdrMenubarTests/ApplicationRuntimeTests.swift`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write no-contact and prompt RED tests**

Cover: local status item/shortcut/settings/store start even when reconnect decisions are pending; a local menu row can select/focus, Toggle Menu works, and Focus Latest routes a local target while the prompt continuation is deliberately blocked; verified stale app-owned control masters are cleaned before prompt but no endpoint contact occurs; one aggregated prompt lists friendly labels only; Reconnect starts all listed endpoints; Not Now starts none and preserves `wasConnected`; next launch prompts again after Not Now; manual disconnect/remove prevents future prompt; prompt dismissal equals Not Now; app stop while prompt is open closes it and performs no contact; stale response after stop is ignored. For shutdown, block a pending marker clear and prove client/tunnel stop have not begun; then release clear and prove ordered completion. Separately force bounded marker-drain failure and prove normal termination is canceled, clients/tunnels remain alive, and retrying quit after clear succeeds.

Record every fake SSH invocation by category. Before explicit Reconnect, permit only identity-verified local control-socket `-O check`/`-O exit` cleanup for a seeded stale manifest; assert discovery and tunnel connection call lists are empty. In the no-stale-manifest case, assert the entire SSH call list is empty. Do not infer no-contact behavior from state alone.

- [ ] **Step 2: Define the prompt seam and decision**

```swift
enum RemoteReconnectDecision: Equatable, Sendable {
    case reconnect(Set<RemoteEndpointID>)
    case notNow
}

@MainActor
protocol RemoteReconnectPrompting: AnyObject {
    func decide(for endpoints: [RemoteEndpoint]) async -> RemoteReconnectDecision
    func stop()
}

enum ApplicationStopResult: Equatable, Sendable {
    case stopped
    case blocked(String)
}

@MainActor
protocol ApplicationRuntimeServing: AnyObject {
    func start() async
    func applicationDidBecomeActive() async
    func stop() async -> ApplicationStopResult
}
```

The live prompt is one native alert/window with `Reconnect` and `Not Now`. Show friendly labels only. It has one owned continuation, idempotent completion, and terminal stop.

- [ ] **Step 3: Integrate consent into runtime startup and shutdown**

Extend `ApplicationRuntimeDependencies` with remote controller/window/prompt hooks; the remote-window stop hook is async because it drains its owned action tasks. Add exact two-phase closures `beginRemoteStop`, `cancelRemoteStop`, `finishRemoteStop`, `prepareStoreStop`, `cancelStoreStop`, and `finishStoreStop` using the token types defined in Task 9; remove the old one-shot `stopStore` closure from live composition. Keep current local startup ordering. After local Observation + `store.start()` returns and ownership is revalidated, set `readyGeneration` immediately so existing local menu actions and shortcuts work. Then launch and retain one generation-owned `remoteConsentTask`; inside it, clean verified stale masters, collect `wasConnected` endpoints, await one prompt, revalidate both runtime and consent-task generations, then connect only the chosen IDs. `start()` does not await the user's decision. App activation refreshes local settings and remote presentation but never implicitly connects.

Normal shutdown is two-phase. First set a runtime stop-preparation token so new menu/shortcut callbacks are inert, call `remoteController.beginTerminalStop()` without withdrawing descriptors/tunnels, and call `store.prepareStop()` while clients/forwards remain live. If store preparation throws, call `store.cancelStopPreparation`, cancel the remote terminal-stop preparation so managers resume their prior generations, clear the runtime preparation token, publish a categorical private-safe error, and return `.blocked`; no UI/client/tunnel ownership is torn down. `HerdrAppDelegate.applicationShouldTerminate` replies `false` for `.blocked`, leaving the app available for retry, and `true` only for `.stopped`.

After successful preparation, invalidate readiness/generation and remote-consent generation; stop shortcuts; stop status/settings windows and prompt; cancel Observation; seal/reset latest target; cancel/drain menu, remote-window, and consent tasks; call `store.finishStop(preparation)` so every supervisor client stops while tunnels remain alive; then call `remoteController.finishTerminalStopAfterSessionClients(token)` to stop/reap tunnels and clear the registry. Repeated stop callers share the exact complete barrier and the `ApplicationRuntimeServing.stop()` contract changes to `async -> ApplicationStopResult`.

- [ ] **Step 4: Run GREEN, lifecycle stress, and commit**

Run `RemoteReconnectPromptTests`, `RemoteSessionsControllerTests`, and `ApplicationRuntimeTests`. Stress blocked prompt + stop, reconnect + stop, and repeated stop callers 100 iterations; run TSan.

```bash
git add HerdrMenubar/Remote/RemoteSessionsController.swift HerdrMenubar/Remote/RemoteReconnectPrompt.swift HerdrMenubar/App/ApplicationRuntime.swift HerdrMenubar/App/HerdrMenubarApp.swift HerdrMenubarTests/RemoteReconnectPromptTests.swift HerdrMenubarTests/ApplicationRuntimeTests.swift HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "feat: ask before reconnecting remote hosts"
```

### Task 13: Compose the live remote graph and targeted actions

**Files:**
- Modify: `HerdrMenubar/App/ApplicationRuntime.swift`
- Modify: `HerdrMenubar/Menu/StatusMenuPresentation.swift`
- Modify: `HerdrMenubar/Herdr/SessionSupervisor.swift`
- Modify: `HerdrMenubarTests/ApplicationRuntimeTests.swift`
- Modify: `HerdrMenubarTests/StatusMenuPresentationTests.swift`
- Modify: `HerdrMenubarTests/SessionSupervisorTests.swift`

- [ ] **Step 1: Write exact live-composition RED tests**

Assert the live graph owns exactly one local discovery, one remote registry, one composite discovery, one supervisor, one endpoint store/controller, one Remote Hosts window, and one reconnect prompt. The same supervisor must serve AgentStore and WezTerm focus; the same host-qualified target flows through notifications and shortcuts.

Assert actions: `openRemoteHosts` opens only that window; `retrySession` on any unavailable row targets exactly that session, and a remote retry also resets only its owning manager/session backoff; no global retry-all action remains. Shutdown must prove remote actions/consent are invalidated first, AgentStore selection clears any installed marker and supervisor clients stop next, and tunnel stop begins last. No app launch, status-menu open, settings open, or activation may contact a remote endpoint absent explicit connect/reconnect consent.

- [ ] **Step 2: Replace local-only composition**

In `ApplicationRuntime.live()`, construct:

```swift
let localDiscovery = SessionDiscovery()
let remoteRegistry = RemoteSessionRegistry()
let discovery = CompositeSessionDiscovery(local: localDiscovery, remote: remoteRegistry)
let supervisor = SessionSupervisor(discovery: discovery, clientFactory: LiveSessionClientFactory())
```

Then compose endpoint persistence, one-shot discovery, tunnel factory, remote controller, Remote Hosts window, and reconnect prompt around the same registry/supervisor. Inject exact action closures into `ApplicationRuntimeDependencies`; do not use globals or a second supervisor.

Replace the dependency's zero-argument `retryStore` closure with `retrySession: (SessionID) async -> Void`. Its local branch calls the supervisor's targeted retry directly; its remote branch calls `RemoteSessionsController.retry(sessionID:)` so both tunnel/discovery backoff and the exact client retry are reset. Runtime owns and drains this async menu action under the existing generation-token action registry.

- [ ] **Step 3: Run GREEN and commit**

Run `ApplicationRuntimeTests`, `SessionSupervisorTests`, `StatusMenuPresentationTests`, `AgentStoreTests`, and all Remote suites. Run a privacy scan for public interpolation of labels/aliases/paths/pane IDs and a persistence scan for credentials/runtime sockets.

```bash
git add HerdrMenubar/App/ApplicationRuntime.swift HerdrMenubar/Menu/StatusMenuPresentation.swift HerdrMenubar/Herdr/SessionSupervisor.swift HerdrMenubarTests/ApplicationRuntimeTests.swift HerdrMenubarTests/StatusMenuPresentationTests.swift HerdrMenubarTests/SessionSupervisorTests.swift
git commit -m "feat: compose remote herdr monitoring"
```

### Task 14: Prove local plus two remote endpoints end to end, document, and release-check

**Files:**
- Modify: `HerdrMenubarTests/MultiSessionIntegrationTests.swift`
- Create: `HerdrMenubarTests/RemoteSSHSubprocessIntegrationTests.swift`
- Modify: `README.md`
- Modify: `HerdrMenubar.xcodeproj/project.pbxproj`

- [ ] **Step 1: Build hermetic fake SSH and three-origin integration fixtures**

The fake SSH executable must implement fixed discovery output, long-lived StreamLocal forwarding, control `check/exit`, delayed/failed discovery, stderr overflow, early exit, TERM-ignore, and process recording without a shell. Fake Herdr servers must expose the real JSON-line request/subscription surface and title events.

Run local default + remote A default + remote B default with the same pane ID. Prove independent snapshots/events, three menu identities, notification payloads, newest-target shortcut routing, notification-click routing, pane focus, marker/title/WezTerm activation, endpoint A transient loss + ten-second grace + exact reconnect, endpoint B unaffected, explicit A disconnect immediate removal/no fallback, and terminal shutdown with every fake child/socket reaped.

If Phase 1 had only one live remote session, the hermetic test must also exercise two sessions on one endpoint with duplicate pane IDs.

- [ ] **Step 2: Capture a genuine integration RED before completing the fixture**

Add the test and fake process/session topology first while leaving one remote registry publication or routing response inert. Run it and require a bounded assertion failure at the missing remote exact-route boundary. Then implement the fixture behavior and make the same test pass. Do not claim a RED from test-only compilation mistakes.

- [ ] **Step 3: Document the exact user contract**

README must state: Remote Hosts uses a friendly name + existing SSH config alias; adding does not connect; Connect/Disconnect are manual; no credentials are stored; restart prompts before reconnect; Not Now applies only to the launch; all running sessions are monitored; local monitoring is independent; failures are endpoint-isolated; exact WezTerm focus requires an existing `herdr --remote` attachment/foreground client; no TCP exposure; no fallback route. Do not promise interactive `ssh host` support.

- [ ] **Step 4: Run automated release gates**

Run:

```bash
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -enableThreadSanitizer YES -only-testing:HerdrMenubarTests/RemoteEndpointManagerTests -only-testing:HerdrMenubarTests/RemoteSessionsControllerTests -only-testing:HerdrMenubarTests/ApplicationRuntimeTests -only-testing:HerdrMenubarTests/MultiSessionIntegrationTests -only-testing:HerdrMenubarTests/RemoteSSHSubprocessIntegrationTests
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS'
release_root="$(mktemp -d /tmp/herdr-menubar-ssh-release.XXXXXX)"
xcodebuild build -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Release -destination 'platform=macOS' -derivedDataPath "$release_root" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
release_app="$release_root/Build/Products/Release/HerdrMenubar.app"
test -d "$release_app"
codesign --verify --deep --strict "$release_app"
lipo -archs "$release_app/Contents/MacOS/HerdrMenubar"
xcodebuild analyze -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
plutil -lint HerdrMenubar.xcodeproj/project.pbxproj HerdrMenubar/Info.plist HerdrMenubar/HerdrMenubar.entitlements
git diff --check origin/master...HEAD
```

The first command is the non-UI suite; the third command is the complete scheme including its UI-test target. If UI automation is unavailable on the machine, that is a release-gate failure to report, not permission to relabel the non-UI run as complete. Require `codesign` exit 0 and `lipo` output containing both `arm64` and `x86_64`.

Stress the three-origin integration and critical start/stop/reconnect tests at least 20 iterations. Verify no fake SSH/Herdr processes, control sockets, forwarded sockets, `/tmp` fixture roots, marker titles, release DerivedData root, or install staging paths remain. Audit for shell invocation, TCP listeners, credential persistence, raw aliases/paths in public logs, and unbounded transport buffers. Remove only the exact recorded `release_root` after checking it is nonempty, begins with `/tmp/herdr-menubar-ssh-release.`, and is owned by the current UID.

- [ ] **Step 5: Repeat the real-host smoke before requesting merge**

Using the same guardrails as Phase 1, exercise the built debug/release app with the real endpoint: add without contact; Test Connection; Connect; all running sessions appear; notification and latest shortcut route exactly; menu click focuses the exact existing remote WezTerm tab; transient loss/reconnect preserves exact target through grace; Disconnect removes immediately and reaps tunnels; restart prompt Reconnect and Not Now semantics; local sessions remain available throughout; clean quit leaves no owned tunnel/control/socket/temp state.

If the host still has only one live session, the final report must say live multi-session remains unexercised and block merge until a two-session live smoke is completed. Any failed cleanup or ambiguous focus blocks merge.

- [ ] **Step 6: Commit docs/integration and request independent final reviews**

```bash
git add HerdrMenubarTests/MultiSessionIntegrationTests.swift HerdrMenubarTests/RemoteSSHSubprocessIntegrationTests.swift README.md HerdrMenubar.xcodeproj/project.pbxproj
git commit -m "test: verify remote herdr sessions end to end"
```

Dispatch independent final spec and quality reviewers. They must inspect the entire branch against the approved design, run focused and full validation, review privacy/process/socket ownership, and explicitly account for the real-host smoke. Remediate findings in separate commits and repeat review. Do not merge, push, or replace the stable installed app without a new user instruction.

## Final implementation report

Return:

- Phase 1 gate table and sanitized evidence;
- feature branch and commit list;
- RED evidence per task;
- focused/stress/TSan/full/Release/Analyze results;
- exact real-host smoke results, including live multi-session status;
- process/socket/temp/title cleanup inventory;
- privacy/persistence audit result;
- independent review verdicts and remediations;
- remaining limitations; and
- explicit statement that merge/push/install were not performed unless separately authorized.
