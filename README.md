# Herdr Menubar

Herdr Menubar is a native, menu-bar-only macOS companion for [Herdr](https://herdr.dev). It provides a persistent, glanceable view of coding agents that are working, blocked, or waiting for attention—even when the terminal is behind another application.

Herdr remains the source of truth. The app reads Herdr's public socket API and does not maintain separate agent status or acknowledgement state.

## Features

- Automatically monitors the default Herdr session and every named session.
- Shows one aggregate attention count in the macOS menu bar.
- Lists blocked and newly completed agents under **Needs Attention**, grouped by session.
- Shows active agents separately under **Working**, grouped by session.
- Uses Herdr-compatible workspace, tab, and agent labels.
- Focuses the exact Herdr pane when an agent is selected.
- Uses native Ghostty Apple Events to focus the owning session's existing terminal surface, or activates another configured terminal application.
- Optionally posts native macOS notifications for new blocked and completed-agent transitions.
- Defaults to Ghostty and discovers supported terminals installed on the Mac.
- Discovers sessions while running and reconnects them independently when Herdr starts, stops, or restarts.
- Keeps healthy sessions visible when another session is unavailable.
- Supports an optional **Launch at Login** setting.
- Supports two independently configurable global keyboard shortcuts.
- Uses a native macOS menu, template icon, accessibility labels, and unified logging.
- Publishes an optional SketchyBar attention badge with access to the native menu.

## Status behavior

The menu reflects Herdr's semantic pane status across all connected sessions:

| Herdr status | Menu behavior |
| --- | --- |
| `blocked` | Appears under **Needs Attention** until the agent can continue. |
| `done` | Appears under **Needs Attention** until Herdr marks the pane as seen. |
| `working` | Appears under **Working**. |
| `idle` | Hidden. |
| `unknown` | Hidden. |

Selecting a row sends `pane.focus` to that row's owning Herdr session. When Ghostty is selected, Herdr Menubar then targets the exact existing terminal surface hosting that session's foreground attached client. It never creates a window, tab, or split, substitutes another session, or falls back to generic Ghostty activation. An unavailable or ambiguous target produces a session-qualified partial-focus error instead. Other recognized terminals, including WezTerm, retain application-level activation without session-aware surface selection.

For completed work, Herdr owns the resulting seen-state transition from `done` to `idle`; Herdr Menubar does not acknowledge it independently.

## Notifications

Native notifications are opt-in. Turn on **Notifications** in the Herdr Menubar menu to request macOS permission in context. The first snapshot from each Herdr session is used only as a baseline, so agents that already need attention when the app starts or notifications are enabled do not produce a notification.

After that baseline, each distinct transition into `blocked` or `done` creates one notification for that pane. A change from `blocked` to `done`, or from `done` to `blocked`, creates another notification because the two states call for different attention. Repeated snapshots and an unchanged reconnect do not create duplicates. **Sound** is a separate opt-in setting, defaults off, and is unavailable while Notifications is off.

**Notification states (new in this version).** Below **Notifications**, a **Herdr Agents** submenu chooses which Herdr states notify: **Blocked** and **Finished**, both on by default. This submenu is the one intentional visible change for Herdr-only installs. When Rex support is active (see [Rex support](#rex-support)), a **Rex Agents** submenu offers **Blocked**, **Failed**, and **Finished**, all on by default (a choice already saved in the submenu is kept). Each parent item shows a checkmark when every state is on, a dash when some are, and nothing when none are. **Notifications** remains the main switch and **Sound** stays app-wide. Clicking a state closes the menu, as native menus do. Unchecked states still update notification history, so turning one back on does not replay old transitions.

Clicking a notification uses the same exact-session focus path as selecting a menu row: it focuses the identified pane in its owning Herdr session and, when Ghostty is selected, focuses that session's exact existing attached Ghostty surface. The latest-notification shortcut uses this same route. Neither route opens a replacement terminal or chooses another session when the original target is unavailable.

Notification labels are visible to macOS and follow the notification-preview choices in System Settings. The menu toggles record local app intent; macOS notification settings, Focus modes, and sound settings can still suppress presentation or sound. If permission is later disabled in System Settings, Herdr monitoring and the menu badge continue to work.

The menu is status-first: **Needs Attention** and **Working** are the top-level sections, with **Default** followed by named-session groups inside each section. The menu-bar badge is the total number of agents under **Needs Attention** across connected sessions: Herdr `blocked` and `done`, plus Rex blocked, failed, and finished agents. An unavailable session's last-known state is removed from the badge and menu immediately, without disturbing healthy sessions.

## Rex support

Herdr Menubar also monitors agents running in [Rex](https://www.superlogical.com/rex/docs), alongside Herdr, in the same menu and badge. Rex support is on by default but does nothing visible unless Rex is installed:

- **Requires Rex.** The app looks for the `rex` CLI bundled with the Rex server (`~/Library/Application Support/com.superlogical.rex/RexServer/Versions/*/…/rex`), then `/opt/homebrew/bin/rex`, `/usr/local/bin/rex`, and `~/.local/bin/rex`. A login-shell `command -v rex` probe runs at most once per launch and only when Rex.app is installed. Without Rex the menu looks exactly as before, apart from the **Herdr Agents** submenu, and the app rechecks those paths every 5 minutes. With Rex installed but its server not running the menu also looks as before, but the app runs the `rex` CLI (`rex version` and `rex --autostart=false server status`, which never starts the server) about once a minute to notice when the server comes up.
- **Rows.** Blocked, failed, and finished Rex agents appear under **Needs Attention** and count toward the badge, just like Herdr's blocked and finished panes. Selecting a finished or failed Rex agent marks it seen and hides it once Rex has switched to it. Because Rex keeps `done` and `error` until they are replaced, **Clear Finished** (or **Clear Finished and Failed**) at the end of **Needs Attention** dismisses all finished Rex agents, and failed ones that have been failed for more than a moment. Seen and cleared Rex agents stay hidden after a relaunch, and show again only when the agent reports a new result. Working Rex agents appear under **Working**.
- **Switching sessions needs Remote Control.** Selecting a Rex row focuses the block on the Rex server and then asks the connected Rex app to show that session. The second step needs **Remote Control** enabled in the Rex app; without it the block is focused but the app shows a partial-focus message instead of switching.

`enabledBackends` and `rexCLIPath` are read once at launch (relaunch after changing them) and are set only with `defaults write dev.herdr.menubar …`. The notify-state keys are written by the submenus and take effect immediately (a value set with `defaults write` applies at the next launch):

| Key | Type | Absent means |
| --- | --- | --- |
| `enabledBackends` | array of `herdr`, `rex` | both (`defaults write dev.herdr.menubar enabledBackends -array herdr` turns Rex off) |
| `rexCLIPath` | string | resolve the Rex CLI automatically |
| `notifyStates.herdr` | array of `blocked`, `done` | `blocked`, `done` (written by the **Herdr Agents** submenu) |
| `notifyStates.rex` | array of `blocked`, `error`, `done` | `blocked`, `error`, `done` (written by the **Rex Agents** submenu) |

The **Rex Agents** submenu appears only when Rex is enabled and has been active during this app run, or when `notifyStates.rex` is already stored.

## Global keyboard shortcuts

Choose **Keyboard Shortcuts** from the Herdr menu to open a small configuration window. Both actions are unassigned by default, can be assigned or cleared independently, and retain their individual assignments across app launches.

- **Toggle Herdr Menu** opens and closes the native Herdr menu globally, including while another application is active.
- **Focus Latest Notification** reuses the exact session and pane from the newest notification accepted for delivery during the current app run. The shortcut can be pressed repeatedly to revisit that target.

Before an accepted notification establishes a current-run target, **Focus Latest Notification** is a silent no-op. If its exact session becomes temporarily unavailable, a shortcut press during the ten-second reconnect grace period remains pending for that target. Reconnecting runs the exact pending focus once. Session removal discards the pending request without selecting another pane or session as a fallback.

Global registration and event delivery use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). Herdr owns the native first-responder recording control for compatibility with macOS 26. Neither recording nor global shortcut use requires Accessibility or Input Monitoring permission.

## Requirements

- A current macOS release supported by the project deployment target.
- A running Herdr default or named session. Exact Ghostty focus requires a foreground attached client and Herdr's client-window-title API; an older unsupported session produces an update message.
- Xcode 26 or newer, including the macOS SDK and command-line tools. After installing Xcode, select it in **Xcode > Settings > Locations**, or with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- Ghostty **1.4.0 or later** with native Apple Event support for exact surface focus, or another recognized terminal for generic application activation. Ghostty is the default. See the live-verification limitation below.

No Homebrew packages, Apple Developer account, or signing certificate are required. Local builds use ad-hoc signing. Notarized packaged releases and Homebrew distribution are not currently included.

## Quick Install

Clone the repository (or run `git pull --ff-only` in an existing checkout), then run:

```bash
./scripts/install.sh
```

The installer signs the local build without a certificate or development team. It ignores
`XCODE_XCCONFIG_FILE` from older install instructions; no signing configuration is needed.
Desktop widgets and their shared App Group are no longer included. The app declares
Apple Events Automation; Xcode can also inject local-development entitlements under the
existing ad-hoc signing settings. No signing team or certificate is needed.

The script makes a Release build using repository-local derived data under `.build/`, installs it as `~/Applications/Herdr Menubar.app`, safely replaces a previous installation, and launches it. It can be invoked from any working directory. To install without launching, use `./scripts/install.sh --no-launch`; `--install-dir DIR` selects a different applications directory.

To update or reinstall, pull the desired source revision and run `./scripts/install.sh` again. The script stops the running app before replacing it, then relaunches the new build. Install and uninstall operations share a per-install-directory lock so they cannot modify the app concurrently. A lock whose numeric owner PID is no longer running is recovered automatically; an invalid lock owner is left in place with a cleanup message so the lock is never removed based on an unsafe guess.

To uninstall:

```bash
./scripts/uninstall.sh
```

This stops Herdr Menubar and removes `~/Applications/Herdr Menubar.app`. Preferences and the Launch at Login system registration are managed separately by macOS; disable **Launch at Login** from the app menu before uninstalling if it was enabled.

Installation does not automatically enable Launch at Login. Use **Launch at Login** in the Herdr Menubar menu if desired.

This local Release build is ad-hoc signed, not Developer ID signed or notarized. Build it on each Mac using the installer. Developer ID signing and notarized release distribution remain future work.

## Build and run

Clone or open the repository, then:

1. Open `HerdrMenubar.xcodeproj` in Xcode.
2. Select the `HerdrMenubar` scheme.
3. Build and run.

The app has no Dock icon or normal application window. After launch, use its terminal-shaped menu-bar icon to:

- Inspect agents needing attention.
- Inspect working agents.
- Select the terminal used for activation.
- Enable or disable Launch at Login.
- Enable native notifications and, independently, notification sound.
- Configure, replace, or clear global keyboard shortcuts.
- Retry unavailable Herdr sessions.
- Quit the app.

You can also build from the command line:

```bash
xcodebuild build \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS'
```

The debug app is written under Xcode's DerivedData directory. When rebuilding while the app is already running, quit or relaunch the existing process so macOS does not continue using a stale binary.

## Herdr session discovery

Herdr Menubar automatically monitors Herdr's public default socket and every direct named-session socket under one configuration base:

```text
~/.config/herdr/herdr.sock
~/.config/herdr/sessions/<name>/herdr.sock
$XDG_CONFIG_HOME/herdr/herdr.sock
$XDG_CONFIG_HOME/herdr/sessions/<name>/herdr.sock
```

When `XDG_CONFIG_HOME` is non-empty, it replaces `~/.config` as that one discovery base. Herdr Menubar never scans both roots together. `HERDR_SOCKET_PATH` and `HERDR_SESSION` do not select or limit the sessions monitored by the app.

The app scans these shallow locations at startup and approximately every two seconds. A newly created default or named session appears without relaunching the app. When a socket disappears, its rows and badge contribution are cleared immediately; the session remains in a reconnecting state for a ten-second grace period so a quick restart can recover without duplicating its group. If the socket remains absent, the session is removed after the grace period.

Each session has its own connection, subscription, snapshot, reconnect loop, and focus routing. A failure in one session therefore leaves healthy session data active. Unavailable sessions appear under **Reconnecting**, and **Retry Unavailable Sessions** immediately retries only unhealthy sessions. The icon is dimmed only when no session is connected; each client uses bounded reconnect backoff and rebuilds its authoritative snapshot after reconnecting.

## Terminal activation

Selecting an agent performs the following sequence:

1. Ask the owning Herdr session to focus the exact pane.
2. When Ghostty is selected, authorize native Apple Events, briefly mark that session's foreground attached client, locate the exact title match within a process-qualified surface snapshot, clear the marker, and focus the matched surface by its stable ID.
3. Otherwise, activate the configured terminal through macOS. Ghostty success or failure never falls through to this generic route.
4. Refresh only the owning Herdr session.

The Ghostty adapter runs only for a menu, notification, or shortcut focus request. It uses native Apple Events, not keystrokes, Accessibility scripting, a CLI, shell hooks, plugins, or terminal configuration changes. Lookup and cleanup are bounded; cancellation and session removal invalidate stale work. No new terminal is created.

The first exact Ghostty focus request may prompt for Automation permission. If denied, allow **Herdr Menubar** to control **Ghostty** in **System Settings > Privacy & Security > Automation**. This is separate from notification permission. If permission, supported scripting, exact lookup, or marker cleanup fails, the pane may already be focused inside Herdr, but terminal focus does not fall back to another target.

The app recognizes these terminal bundle identifiers:

- WezTerm
- Ghostty
- iTerm2
- Terminal
- Kitty
- Alacritty

If the configured terminal is unavailable, the menu retains the preference as unavailable and offers installed alternatives. Existing saved WezTerm selections migrate to Ghostty once; selections of other terminals are preserved. After that migration, explicitly selecting WezTerm again remains a valid generic-activation choice.

## Architecture

The app uses KeyboardShortcuts 3.0.1 for global shortcut persistence, registration, and event delivery. Its own code is split into focused components:

```text
HerdrMenubar/
├── App/       Application lifecycle and live dependency composition
├── Herdr/     API models, socket discovery, transport, and synchronization
├── Menu/      Native status item, menu presentation, and icon rendering
├── Notifications/ Native notification transitions, delivery, and settings
├── Shortcuts/ Global registration, event routing, settings, and native recording
├── Status/    Observable presentation state and user actions
└── System/    Preferences, terminal activation, logging, and login items
```

The main runtime boundaries are:

- **`SessionDiscovery`** — finds the default and direct named-session public sockets under the active configuration root.
- **`SessionSupervisor`** — owns one `HerdrClient` per discovered session and isolates discovery, reconnect, retry, and removal behavior.
- **`HerdrClient`** — an actor that owns one session's socket requests, event subscriptions, snapshots, reconnects, and synchronization generations.
- **`AgentStore`** — a main-actor observable model that aggregates session-qualified menu sections and coordinates routed focus and activation.
- **`LiveGhosttyFocusAdapter`** — coordinates exact marker lookup, clear-before-focus, cancellation, and per-session cleanup lifecycle.
- **`LiveGhosttyControl` / `LiveGhosttyAppleEventTransport`** — validate the running process and supported version, authorize Automation, and encode bounded native surface enumeration/focus events.
- **`AttentionNotificationCoordinator`** — tracks per-session pane transitions and suppresses startup and reconnect duplicates.
- **`NativeNotificationService`** — owns macOS permission, delivery, and exact session-and-pane response routing.
- **`GlobalShortcutController`** — consumes registered key-up events and routes menu toggles or the current-run notification target.
- **`NWHerdrConnection`** — a Network.framework Unix-domain socket adapter using newline-delimited JSON.
- **`LoginItemService`** — a testable wrapper around `SMAppService.mainApp`.

Herdr event subscriptions use one long-lived socket. Ordinary snapshot and focus requests use short-lived sockets, matching Herdr's public API connection behavior. Since status subscriptions are pane-scoped, the client rebuilds its subscription when pane membership changes.

Detailed design and implementation planning are available in:

- [`docs/superpowers/specs/2026-07-11-herdr-menubar-design.md`](docs/superpowers/specs/2026-07-11-herdr-menubar-design.md)
- [`docs/superpowers/plans/2026-07-11-herdr-menubar-implementation.md`](docs/superpowers/plans/2026-07-11-herdr-menubar-implementation.md)

## Development and validation

Run the non-UI unit suite:

```bash
xcodebuild test \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS' \
  -only-testing:HerdrMenubarTests
```

Build and run static analysis:

```bash
xcodebuild build \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS'

xcodebuild analyze \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS'
```

The unit suite is hermetic and suppresses production Herdr synchronization while hosted by XCTest. Hosted preferences use a private suite before any default migration, leaving real saved preferences untouched. Transport and synchronization tests use fake or temporary Unix-domain sockets; Ghostty tests inject permission and event-send boundaries and never request Automation consent or contact live Ghostty.

The UI-test target is present for future smoke coverage, but routine validation uses unit tests plus a bounded ordinary-app launch. Do not use unsigned UI-test runners for local validation; macOS may reject those runner bundles.

## Preferences and privacy

The app persists these preferences:

- Selected terminal bundle identifier.
- Launch at Login intent.
- Notifications intent.
- Notification sound intent.
- Per-backend notification states (`notifyStates.herdr`, `notifyStates.rex`), written only when changed.
- Seen and cleared Rex agents (`rexDismissedRecords`, at most 500), so they stay hidden across launches.
- `enabledBackends` and `rexCLIPath`, read only (set with `defaults write`; see [Rex support](#rex-support)).
- Toggle-menu shortcut assignment.
- Latest-notification shortcut assignment.

The app also records whether the one-time Ghostty default migration has run. Native Automation decisions remain managed by macOS, not by these preferences.

Actual login-item state is read from macOS through `SMAppService`. The app writes aggregate connection and attention status for SketchyBar to a private local file. Herdr remains the source of truth for agent status and acknowledgement state.

Runtime diagnostics use the unified logging subsystem `dev.herdr.menubar`. Dynamic socket, server, focus, activation, and error details are logged as private values.

## Current limitations

- Local source build and install workflow only.
- No Developer ID signed or notarized release artifacts; the installer builds and signs locally without a certificate.
- No automatic updater or package-manager installation.
- Menu presentation intentionally uses native macOS menu behavior rather than a custom dashboard or popover.
- Terminal activation uses a user-selected terminal because Herdr's public API does not currently identify the macOS application hosting an attached client.
- Ghostty routing, native event encoding, denial/cancellation, identity checks, and marker cleanup have hermetic automated coverage. Live title propagation, exact tab/split/window focus, Automation attribution, and installed-app compatibility are still unverified; no live rollout claim is made.
- The build-7 non-UI reassessment ran 436 tests; its only failures are three pre-existing rendered shortcut-error accessibility assertions. Reconnect and Ghostty migration cases passed, but full-green release validation remains blocked separately from this migration.

## License and disclaimer

Herdr Menubar is available under the [MIT License](LICENSE).

The project is provided **as is**, without warranty of any kind. If you clone, modify, install, or redistribute it, you are responsible for reviewing the code and scripts, validating them in your environment, and maintaining your copy. Compatibility with future macOS, Xcode, terminal, or Herdr releases is not guaranteed, and no support, uptime, data-safety, or fitness-for-purpose commitment is implied.

Herdr is a separate project with its own license and maintainers. References to Herdr and supported terminal applications describe interoperability and do not imply endorsement or affiliation.

## Updating from a version with desktop widgets

Run `./scripts/install.sh` normally. The installer replaces the entire application bundle,
so the retired extension is removed. Remove any old Herdr tiles from your desktop.
If you installed `herdr-widget-activity.ts` into `~/.pi/agent/extensions/`, remove that
companion and run `/reload` in existing Pi sessions; it is no longer used.
Existing preferences and historical App Group files are left untouched.

`Config/Version.xcconfig` contains the application build number. The installer validates
the app bundle and local signature before replacing an existing install, stops the
installed processes, and refreshes only this checkout's app registrations. Registration
failure retains the prior app backup and reports its path.

## SketchyBar

Herdr Menubar can publish a live attention badge and open its native menu from SketchyBar. See [setup and status contract](integrations/sketchybar/README.md). This works independently of notification preferences.

The macOS app icon lives in `HerdrMenubar/Assets.xcassets/AppIcon.appiconset`; the small menu-bar glyph remains the system terminal symbol.
