# Ghostty Focus Feasibility Check

**Date:** 2026-11-03

**Status:** Live checks remain deferred by the user's implementation-first direction (“keep going”). Build 7 implements native production integration, safe defaults migration, packaged Automation declarations, and obsolete-backend retirement. The 176-test post-retirement checkpoint and 32 mocked installer cases passed. A reconnect/discovery race reached deterministic RED -> GREEN, passed 42 supervisor/integration tests and 150 repeated executions, then passed the full reassessment's reconnect/native cases. That full run executed 436 tests and failed only the same three separately reproduced accessibility assertions. Release build, read-only signature/entitlement/purpose/version checks, and the Xcode analyze action passed. The signature was reverified after analyze; its incremental success is not complete Swift static-analysis evidence. No full-green release, live compatibility, or Automation attribution is claimed.

## Installation and publication approval

On 2026-11-04 the user explicitly approved installing, launching, committing, and pushing build 7. Installer `b0232e7aa` completed successfully: build 7 is installed at `~/Applications/Herdr Menubar.app` and launched. Read-only checks verified its strict/deep signature, embedded Automation entitlement/purpose, build number, and a running process at that exact installed executable path. These are installation/startup checks, not native focus or Automation-attribution proof. This supersedes only the installation/launch/publication deferral. Normal app launch may apply the documented one-time terminal preference migration. The agent will not trigger terminal focus, change titles or Automation permissions, or repair unrelated tests. The verified publication destination is `master` -> `origin/master` at `https://github.com/sendhil/herdr-menubar.git`; generated `.pi/` artifacts are excluded.

## Scope and approval

The following records the earlier implementation-only phase; the newer installation/publication approval above supersedes its install/launch restrictions.

The user initially approved proceeding with the migration plan and confirmed that the default Herdr session is attached in Ghostty with a non-agent idle pane reserved for a live check. That earlier live approval is historical: the current implementation-first direction defers title changes, live focus, and Automation prompts. The current task permits implementation and hermetic automated verification only.

The agent's shell does **not** have `HERDR_ENV=1`. Herdr's installed skill requires that context for live session inspection/control. The agent therefore has not queried or mutated the live session and will not bypass the guard. A disposable app and guarded launcher were prepared, but the user subsequently deferred this interaction and asked to proceed with implementation and automated tests. Do not launch or ask the user to launch that probe during this implementation.

## Read-only baseline

- Repository HEAD: `fa1b01d3656b94e842cf96312bb1ccae4969c860`.
- Herdr: 0.9.5.
- Ghostty: 1.4.0, stable.
- macOS: 26.7.1 (25G241).
- Existing untracked work: `.pi/` and the migration plan.
- Baseline unit suite: **FAILED**, exit 65. Executed 417 tests with three assertion failures in one test: `KeyboardShortcutSettingsTests.testRenderedErrorAccessibilitySpeaksActionAndExactDynamicReason` at lines 173, 176, and 185. The reported accessibility string arrays were empty. No production sources were changed before this run. The WezTerm CLI/focus/subprocess suites passed. The isolated reproduction also failed with the same three assertions and empty accessibility arrays (one test, three failures, exit 65). Suite ordering alone does not explain the failure. No unrelated fix has been attempted; the shortcut/accessibility failure remains a known baseline blocker.

## Disposable probe

Temporary directory: `/tmp/herdr-ghostty-probe.MWWhmQ`.

- `main.swift`: throwaway native Apple Event probe. This is an explicitly stated exploratory prototype, not TDD production implementation; do not promote it into production.
- `Herdr Menubar.app`: temporary ad-hoc-signed app with `dev.herdr.menubar` bundle ID and the planned Automation usage description.
- `run-from-herdr.sh`: requires the user's actual `HERDR_ENV`, `HERDR_SOCKET_PATH`, and `HERDR_PANE_ID`; launches that exact temporary app with those inherited values. It does not choose a socket, create an attachment, or forge Herdr context.
- `result.json`: private, bounded summary with stages/error codes only; no titles, socket paths, terminal IDs, or agent contents.

The app first resolves permission, checks that its inherited Herdr pane is focused/non-agent/idle, and requires an existing distractor terminal. It then sets an opaque marker through the repository's existing Herdr client, matches the exact terminal title, clears the marker, verifies title restoration, focuses a distractor and then the target by stable ID, checks selected-tab/focused-terminal identity, and compares surface inventories. Cleanup is attempted on failure. No window/tab/split creation, terminal input, configuration mutation, or server restart is included.

The user must not have a pre-existing `client.window_title.set` override active for this check; the normal Herdr client title should be visible before launching. Ghostty's own title overrides are not modified.

## Gates

| Gate | Status | Evidence |
| --- | --- | --- |
| Unchanged baseline unit suite | FAIL | 417 tests; three assertions failed in the single rendered shortcut-error accessibility test. Isolated run reproduced the same failures. |
| Disposable probe compilation/signature | PASS | Swift 6 compilation, ad-hoc signing, strict signature verification, and launcher shell syntax validation completed with exit 0. No compiler warnings in the successful run. App not launched. |
| Native Automation consent and actual-app attribution | NOT RUN | Requires user launch and Automation UI confirmation. |
| Exact Herdr marker propagation | NOT RUN | Requires user launch inside reserved Herdr pane. |
| Marker clearing and original title restoration | NOT RUN | Requires user launch. |
| Stable-ID focus after marker clearing | NOT RUN | Requires user launch. |
| Selected tab/window/split identity | NOT RUN | Probe verifies focused terminal of selected tab of front window; topology coverage must be recorded separately. |
| No new Ghostty surfaces | NOT RUN | Probe compares stable surface ID inventories. |
| Denied permission / disabled scripting | NOT RUN | No live TCC/configuration changes made. |
| Closed target / Ghostty exit / replacement | NOT RUN | No Ghostty or Herdr session stopped. The approved installer manages only the owned installed Herdr Menubar process. |
| Hermetic integration and packaged declarations | PASS | 176 post-retirement tests, 32 mocked installer cases, 42 supervisor/integration cases, and 150 repeated reconnect/regression executions passed. Debug test-host and Release signature/Automation entitlement verified; no live Automation boundary executed. |
| Full non-UI reassessment | FAIL — baseline only | 436 tests, three assertions in the unchanged rendered shortcut-accessibility test; no reconnect/Ghostty failure. |
| Release build/signature/purpose/version | PASS | `bf06653f2` built universal arm64/x86_64 Release; strict/deep signature valid, ad-hoc identity, Automation purpose/entitlement present, build 7, deployment 26.0. Xcode also injected get-task-allow under unchanged local signing settings. The subsequently approved installed artifact also passed signature/entitlement/purpose/build checks. |
| Xcode analyze / scoped LSP | PASS — scoped evidence | `b3e9aa9ef` succeeded with no source diagnostics or new Launch Services step; the incremental log has no fresh Swift compile/analyzer pass. All 19 changed Swift files passed active LSP. Broader AST/opengrep/Markdown coverage remains incomplete, not clean. |
| Installed artifact and startup | PASS — limited | `b0232e7aa` installed/launched build 7; signature/Automation declaration/version and running installed-path process verified. Exact surface focus, title restoration, and Automation attribution remain NOT RUN. |

## Next action

The implementation and non-live verification are at handoff: backend retirement, installer, build number, full-suite assessment, Release build/signature/entitlement/purpose/version checks, and Xcode analyze action are recorded. Full-green release remains blocked by the separately reproduced accessibility baseline; broader static-analysis coverage remains incomplete. Unrelated baseline repair and terminal-focus/title/Automation verification still require new approval. Installation and app launch completed as recorded above. No agent-triggered probe launch, terminal-focus/title mutation, configuration/permission change, or Automation request was performed. Xcode's Release build log included its automatic Launch Services registration step for the DerivedData artifact; no manual registration reversal was attempted. The historical temporary probe directory is no longer present; regenerate a fresh probe only if live verification is approved later. The reproduced baseline accessibility failure remains documented and unresolved.

## Development analyzer context

Standalone SourceKit initially rooted itself in individual source directories, reporting missing sibling types and XCTest despite successful complete-module typechecking/Xcode target compilation. A separate real fixture error (`descriptor(forKeyword:)` instead of Foundation's Swift `forKeyword(_:)`) was identified and corrected; compile failures are not counted as TDD RED.

A local, non-shipped Xcode build-server bridge is configured to give SourceKit the correct project context. The real build log was parsed into `.compile`; three stale SourceKit helpers owned by this Pi session and rooted in individual source directories were terminated, leaving the correctly rooted repo helper. Definition navigation now resolves `SessionID` to `SessionDiscovery.swift`, and a fresh write/analysis cleared all eight adapter scope blockers without adding imports or duplicating declarations. `xcode-build-server` v1.3.0 was extracted under `.pi/sourcekit-tools/` from the upstream source archive, verified against Homebrew's SHA-256 `92c4bb848af5c8128d4600a93f45e49b89ed953d885c60092459303a5d80e312`. Generated `buildServer.json` / `.compile` and the helper directory are excluded locally via `.git/info/exclude`; there is no global installation or app runtime dependency.
