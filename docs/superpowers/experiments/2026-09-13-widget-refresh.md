# Native widget feasibility: execution record

Date: 2026-09-13
Branch: `codex/native-widget-prototype`
Status: Built and installed; desktop validation pending unlock.

## Environment

- macOS 26.6.2 (25G83), Xcode 26.6 (17F113).
- Deployment target remains macOS 26.0.
- Apple Development signing, manual selection of an existing valid certificate.
- App Group uses the macOS team-prefixed convention: `$(DEVELOPMENT_TEAM).dev.herdr.widgets`.
- Widget developer-mode setting and power state have not been inspected because the desktop is locked.
- Release app launched through Launch Services, outside Xcode and its debugger.

The initial sandboxed identity lookup returned zero identities. The unrestricted read-only lookup found valid development identities; no certificate or developer account was created.

## Installation

Release build succeeded. Strict signature validation passed for both the application and extension. The Release extension has the App Sandbox entitlement and the expected App Group entitlement. Debug test builds include XCTest-generated entitlements; those were not used as the installed product.

Installed at `~/Applications/Herdr Menubar.app` using the existing install script with an explicit temporary signing xcconfig. A pre-install backup is retained at `.build/HerdrMenubar-before-widgets.app` in this worktree. Existing preferences and login-item intent were not changed.

`pluginkit -m -A -D -v -i dev.herdr.menubar.widgets` confirms registration at the installed application's `Contents/PlugIns/HerdrWidgets.appex`. Xcode's Debug and Release build paths are also registered by the build system. Registration is established; gallery placement has not been verified.

## Shared data

The installed app launched with `--widget-refresh-probe`. Its own runtime logs confirm successful atomic writes at 14:38:40 and 14:39:10 local time, with distinct generation UUIDs and sequence values 1 and 2. This confirms publication by the real app at the planned 30-second cadence. These are not desktop-render measurements.

The shared snapshot file exists. A direct read from a separate shell process did not complete promptly and was cancelled; it is not evidence that the entitled widget cannot read the file. Shared-container access by the extension itself remains to be exercised through WidgetKit.

## Automated verification

- Baseline: 397 tests, four failed assertions across two existing tests: a subprocess overflow timing assertion and three shortcut accessibility assertions.
- New tests: seven pass, covering atomic replacement/round trip, missing and corrupt input, unsupported schema, freshness boundaries, write-before-reload ordering, no reload after write failure, and probe opt-in/test suppression.
- Full post-change suite: 404 tests, three failed assertions, all in the existing `KeyboardShortcutSettingsTests.testRenderedErrorAccessibilitySpeaksActionAndExactDynamicReason`. Accessibility enumeration returned an empty array. The subprocess timing assertion passed on this run. No new failing tests.
- Release static analysis succeeded.
- Xcode warns that app-intent metadata extraction is skipped for the containing app because it does not depend on AppIntents. The static probe has no app intents.

## Visible refresh results

No visible samples have been collected. The computer-use tool reports that the Mac is locked and cannot be automatically unlocked. Do not infer display latency from the successful writes, registration, or a future provider callback.

Pending after unlock:

1. Confirm WidgetKit developer mode is disabled without changing it silently.
2. Add the installed Herdr refresh probe to the native desktop widget gallery.
3. Observe its generation, app-write time, and provider-read time.
4. Record visible timing over the planned sample set, covered-desktop returns, and sleep/wake.
5. Exercise two instances and quit/relaunch behavior.

## Lifecycle and probe limits

The probe is disabled on ordinary launches and in XCTest. When explicitly launched with `--widget-refresh-probe`, it publishes 30 generations at 30-second intervals, then stops. Add `--widget-refresh-probe-fast` for the later five-second-cadence experiment. Relaunch to start a fresh run.

Publication stops when the application terminates. The widget schedules an explicit old-snapshot entry 90 seconds after the last snapshot. This is a diagnostic threshold, not the production stale-state policy. Missing or unsupported data shows an unavailable view; gallery previews are identified separately.

## Recommendation

Continue with the actual desktop test once the Mac is unlocked. Installation/signing and app-side publication are established. Extension reads and few-second visible refresh behavior are not yet established. Accurate user-message tracking, configurable filters, the approved agent-list layout, and click-through navigation remain subsequent milestones.
