# Native widget feasibility: execution record

Date: 2026-09-13
Branch: `codex/native-widget-prototype`
Status: Built and installed; shared-container reads and 30-update refresh run verified. Visible-render validation remains pending.

## Environment

- macOS 26.6.2 (25G83), Xcode 26.6 (17F113).
- Deployment target remains macOS 26.0.
- Apple Development signing, manual selection of an existing valid certificate.
- App Group uses the macOS team-prefixed convention: `$(DEVELOPMENT_TEAM).dev.herdr.widgets`.
- Mac unlocked for the second run. Widget developer-mode state has not been conclusively verified. Read-only inspection of `com.apple.chronod` and `com.apple.WidgetKit` preferences found no explicit override, but this alone does not prove that developer mode is disabled.
- Release app launched through Launch Services, outside Xcode and its debugger.

The initial sandboxed identity lookup returned zero identities. The unrestricted read-only lookup found valid development identities; no certificate or developer account was created.

## Installation

Release build succeeded. Strict signature validation passed for both the application and extension. The Release extension has the App Sandbox entitlement and the expected App Group entitlement. Debug test builds include XCTest-generated entitlements; those were not used as the installed product.

Installed at `~/Applications/Herdr Menubar.app` using the existing install script with an explicit temporary signing xcconfig. A pre-install backup is retained at `.build/HerdrMenubar-before-widgets.app` in this worktree. Existing preferences and login-item intent were not changed.

`pluginkit -m -A -D -v -i dev.herdr.menubar.widgets` confirms registration at the installed application's `Contents/PlugIns/HerdrWidgets.appex`. Xcode's Debug and Release build paths are also registered by the build system. Registration and presence in the native widget gallery are established. The Herdr category and its medium refresh-probe add control were activated. Desktop placement has not been visually confirmed because the computer-use tool continued targeting the existing Weather widget.

## Shared data

The installed app launched with `--widget-refresh-probe`. Its own runtime logs confirm successful atomic writes at 14:38:40 and 14:39:10 local time, with distinct generation UUIDs and sequence values 1 and 2. This confirms publication by the real app at the planned 30-second cadence. These are not desktop-render measurements.

The shared snapshot file exists. A direct read from a separate shell process did not complete promptly and was cancelled; it is not evidence that the entitled widget cannot read the file. After unlock, the entitled WidgetKit extension successfully read the snapshot. Shared-container access by the extension is now established.

## Automated verification

- Baseline: 397 tests, four failed assertions across two existing tests: a subprocess overflow timing assertion and three shortcut accessibility assertions.
- New tests: seven pass, covering atomic replacement/round trip, missing and corrupt input, unsupported schema, freshness boundaries, write-before-reload ordering, no reload after write failure, and probe opt-in/test suppression.
- Full post-change suite: 404 tests, three failed assertions, all in the existing `KeyboardShortcutSettingsTests.testRenderedErrorAccessibilitySpeaksActionAndExactDynamicReason`. Accessibility enumeration returned an empty array. The subprocess timing assertion passed on this run. No new failing tests.
- Release static analysis succeeded.
- Xcode warns that app-intent metadata extraction is skipped for the containing app because it does not depend on AppIntents. The static probe has no app intents.

## Visible refresh results

The native gallery showed **Herdr Menubar → Herdr refresh probe (Medium)**. After activating the add control and leaving the gallery, the automation tool continued selecting the existing Forecast widget rather than Herdr. Attempts to target the Herdr window were unsuccessful. The user was asked to right-click the Herdr widget so it could be inspected. No visible-render samples are claimed.

A fresh Release-app run began at 15:37:38 local time with `--widget-refresh-probe --widget-refresh-probe-fast`. The app was opened in the background through Launch Services. Correlation by generation UUID over all 30 writes produced:

| Measurement | Result |
| --- | --- |
| Publication cadence | Approximately 5 seconds |
| Distinct published generations | 30 |
| Distinct generations read by WidgetKit | 30 |
| Published generations without a read | 0 |
| Median write-to-first-provider-read delay | 29.4 ms |
| 95th percentile (nearest rank) | 45.1 ms |
| Maximum | 64.1 ms |

These are app-to-provider measurements, not app-to-screen latency. The run supports the event-driven architecture, but does not establish the proposed visible-refresh threshold or long-term budget behavior. It also does not replace the planned 30-second cadence baseline under fully verified settings. The bounded publisher stopped automatically after generation 30.

Still pending:

1. Confirm WidgetKit developer mode is disabled.
2. Inspect the actual Herdr desktop widget and observe generation changes.
3. Record visible timing over the planned sample set, covered-desktop returns, and sleep/wake.
4. Exercise two instances and confirm the old-snapshot presentation after publication stops.

## Lifecycle and probe limits

The probe is disabled on ordinary launches and in XCTest. When explicitly launched with `--widget-refresh-probe`, it publishes 30 generations at 30-second intervals, then stops. Add `--widget-refresh-probe-fast` for the later five-second-cadence experiment. Relaunch to start a fresh run.

Publication stops when the application terminates. The widget schedules an explicit old-snapshot entry 90 seconds after the last snapshot. This is a diagnostic threshold, not the production stale-state policy. Missing or unsupported data shows an unavailable view; gallery previews are identified separately.

## Recommendation

Continue with the actual desktop rendering test. Installation/signing, shared-container reads, and prompt delivery of all 30 background publications are established. Few-second visible refresh behavior is not yet established. Accurate user-message tracking, configurable filters, the approved agent-list layout, and click-through navigation remain subsequent milestones.
