# Herdr Menubar

Herdr Menubar is a native, menu-bar-only macOS companion for [Herdr](https://herdr.dev). It provides a persistent, glanceable view of coding agents that are working, blocked, or waiting for attention—even when the terminal is behind another application.

Herdr remains the source of truth. The app reads Herdr's public socket API and does not maintain separate agent status or acknowledgement state.

## Native widget prototype

This branch includes a native WidgetKit refresh probe embedded in Herdr Menubar. It is a feasibility build, not yet the configurable agent-list widget. The planned design and measured implementation status are in [the widget experiment record](docs/superpowers/experiments/2026-09-13-widget-refresh.md).

The widget's shared container requires development-team signing. Ad-hoc signing does not establish widget shared-container access. For widget testing, provide `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE = Manual`, and a matching `CODE_SIGN_IDENTITY` in a local xcconfig file. Pass that file to the existing installer through `XCODE_XCCONFIG_FILE`:

```bash
XCODE_XCCONFIG_FILE=/tmp/herdr-widget-signing.xcconfig ./scripts/install.sh --no-launch
open -g "$HOME/Applications/Herdr Menubar.app" --args --widget-refresh-probe
```

The app and extension derive their macOS App Group from `$(DEVELOPMENT_TEAM).dev.herdr.widgets`. Select an existing valid Apple Development identity from `security find-identity -v -p codesigning`; keep personal signing settings outside the repository.

Add **Herdr refresh probe** from the macOS widget gallery. It displays a sequence number, short generation ID, app-write time (up arrow), and provider-read time (down arrow). The explicit probe run produces 30 updates at 30-second intervals. A normal app launch starts no probe. Quit before relaunching with probe arguments; passing arguments to an already-running app does not start a new run. The later fast-cadence test adds `--widget-refresh-probe-fast` for five-second intervals.

Measure the installed Release app outside Xcode with widget developer mode disabled. A provider read or an update request is not evidence of a visible desktop refresh. Do not use this diagnostic widget as a live agent-status display.

## Features

- Automatically monitors the default Herdr session and every named session.
- Shows one aggregate attention count in the macOS menu bar.
- Lists blocked and newly completed agents under **Needs Attention**, grouped by session.
- Shows active agents separately under **Working**, grouped by session.
- Uses Herdr-compatible workspace, tab, and agent labels.
- Focuses the exact Herdr pane when an agent is selected.
- Switches to the owning session's existing WezTerm tab, or activates another configured terminal application.
- Optionally posts native macOS notifications for new blocked and completed-agent transitions.
- Defaults to WezTerm and discovers supported terminals installed on the Mac.
- Discovers sessions while running and reconnects them independently when Herdr starts, stops, or restarts.
- Keeps healthy sessions visible when another session is unavailable.
- Supports an optional **Launch at Login** setting.
- Supports two independently configurable global keyboard shortcuts.
- Uses a native macOS menu, template icon, accessibility labels, and unified logging.
- Stores preferences only; pane and agent state is never persisted.

## Status behavior

The menu reflects Herdr's semantic pane status across all connected sessions:

| Herdr status | Menu behavior |
| --- | --- |
| `blocked` | Appears under **Needs Attention** until the agent can continue. |
| `done` | Appears under **Needs Attention** until Herdr marks the pane as seen. |
| `working` | Appears under **Working**. |
| `idle` | Hidden. |
| `unknown` | Hidden. |

Selecting a row sends `pane.focus` to that row's owning Herdr session. When WezTerm is selected, Herdr Menubar also switches to the existing WezTerm tab containing that session's foreground attached client. It never opens a new tab when no client is attached; the menu reports that partial-focus condition instead. Other recognized terminals retain application-level activation without session-aware tab selection.

For completed work, Herdr owns the resulting seen-state transition from `done` to `idle`; Herdr Menubar does not acknowledge it independently.

## Notifications

Native notifications are opt-in. Turn on **Notifications** in the Herdr Menubar menu to request macOS permission in context. The first snapshot from each Herdr session is used only as a baseline, so agents that already need attention when the app starts or notifications are enabled do not produce a notification.

After that baseline, each distinct transition into `blocked` or `done` creates one notification for that pane. A change from `blocked` to `done`, or from `done` to `blocked`, creates another notification because the two states call for different attention. Repeated snapshots and an unchanged reconnect do not create duplicates. **Sound** is a separate opt-in setting, defaults off, and is unavailable while Notifications is off.

Clicking a notification uses the same exact-session focus path as selecting a menu row: it focuses the identified pane in its owning Herdr session and, when WezTerm is selected, activates that session's existing attached WezTerm tab. It does not open a replacement tab or choose another session when the original target is unavailable.

Notification labels are visible to macOS and follow the notification-preview choices in System Settings. The menu toggles record local app intent; macOS notification settings, Focus modes, and sound settings can still suppress presentation or sound. If permission is later disabled in System Settings, Herdr monitoring and the menu badge continue to work.

The menu is status-first: **Needs Attention** and **Working** are the top-level sections, with **Default** followed by named-session groups inside each section. The menu-bar badge is the total number of `blocked` and `done` agents across connected sessions. An unavailable session's last-known state is removed from the badge and menu immediately, without disturbing healthy sessions.

## Global keyboard shortcuts

Choose **Keyboard Shortcuts** from the Herdr menu to open a small configuration window. Both actions are unassigned by default, can be assigned or cleared independently, and retain their individual assignments across app launches.

- **Toggle Herdr Menu** opens and closes the native Herdr menu globally, including while another application is active.
- **Focus Latest Notification** reuses the exact session and pane from the newest notification accepted for delivery during the current app run. The shortcut can be pressed repeatedly to revisit that target.

Before an accepted notification establishes a current-run target, **Focus Latest Notification** is a silent no-op. If its exact session becomes temporarily unavailable, a shortcut press during the ten-second reconnect grace period remains pending for that target. Reconnecting runs the exact pending focus once. Session removal discards the pending request without selecting another pane or session as a fallback.

Global registration and event delivery use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). Herdr owns the native first-responder recording control for compatibility with macOS 26. Neither recording nor global shortcut use requires Accessibility or Input Monitoring permission.

## Requirements

- A current macOS release supported by the project deployment target.
- A running Herdr default or named session. Session-aware WezTerm tab focus is verified with Herdr 0.7.3 or newer.
- Xcode 26 or newer, including the macOS SDK and command-line tools. After installing Xcode, select it in **Xcode > Settings > Locations**, or with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- One of the recognized terminal applications for click-through activation. WezTerm is the default; session-aware tab focus requires the installed app's `Contents/MacOS/wezterm` CLI.

No Homebrew packages or third-party build tools are required. Signing, notarization, packaged releases, and Homebrew distribution are not currently included.

## Quick Install

Clone the repository, then run this command from the checkout:

```bash
./scripts/install.sh
```

The script makes a Release build using repository-local derived data under `.build/`, installs it as `~/Applications/Herdr Menubar.app`, safely replaces a previous installation, and launches it. It can be invoked from any working directory. To install without launching, use `./scripts/install.sh --no-launch`; `--install-dir DIR` selects a different applications directory.

To update or reinstall, pull the desired source revision and run `./scripts/install.sh` again. The script stops the running app before replacing it, then relaunches the new build. Install and uninstall operations share a per-install-directory lock so they cannot modify the app concurrently. A lock whose numeric owner PID is no longer running is recovered automatically; an invalid lock owner is left in place with a cleanup message so the lock is never removed based on an unsafe guess.

To uninstall:

```bash
./scripts/uninstall.sh
```

This stops Herdr Menubar and removes `~/Applications/Herdr Menubar.app`. Preferences and the Launch at Login system registration are managed separately by macOS; disable **Launch at Login** from the app menu before uninstalling if it was enabled.

Installation does not automatically enable Launch at Login. Use **Launch at Login** in the Herdr Menubar menu if desired.

This local Release build is ad-hoc signed by Xcode; it is not Developer ID signed or notarized. macOS Gatekeeper may ask you to confirm opening it. Developer ID signing and notarized release distribution remain future work; do not bypass organizational security policy to run the app.

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
2. When WezTerm is selected, briefly mark that session's foreground attached client, locate its existing pane with the installed WezTerm CLI, clear the marker, and activate that pane.
3. Activate the configured terminal through macOS.
4. Refresh only the owning Herdr session.

The WezTerm adapter runs only when a row is clicked. It installs no background helper, shell hook, or WezTerm configuration, and it never creates a tab.

The app recognizes these terminal bundle identifiers:

- WezTerm
- Ghostty
- iTerm2
- Terminal
- Kitty
- Alacritty

If the configured terminal is unavailable, the menu retains the preference as unavailable and offers installed alternatives.

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

The unit suite is hermetic and suppresses production Herdr synchronization while hosted by XCTest. Transport and synchronization tests use fake or temporary Unix-domain sockets.

The UI-test target is present for future smoke coverage, but routine validation uses unit tests plus a bounded ordinary-app launch. Do not use unsigned UI-test runners for local validation; macOS may reject those runner bundles.

## Preferences and privacy

The app persists only:

- Selected terminal bundle identifier.
- Launch at Login intent.
- Notifications intent.
- Notification sound intent.
- Toggle-menu shortcut assignment.
- Latest-notification shortcut assignment.

Actual login-item state is read from macOS through `SMAppService`. Pane snapshots, agent status, terminal output, session state, and acknowledgement state are not written to disk by Herdr Menubar. Herdr remains the source of truth for all runtime state.

Runtime diagnostics use the unified logging subsystem `dev.herdr.menubar`. Dynamic socket, server, focus, activation, and error details are logged as private values.

## Current limitations

- Local source build and install workflow only.
- No Developer ID signed or notarized release artifacts; local builds are ad-hoc signed and distributable releases remain future work.
- No automatic updater or package-manager installation.
- Menu presentation intentionally uses native macOS menu behavior rather than a custom dashboard or popover.
- Terminal activation uses a user-selected terminal because Herdr's public API does not currently identify the macOS application hosting an attached client.

## License and disclaimer

Herdr Menubar is available under the [MIT License](LICENSE).

The project is provided **as is**, without warranty of any kind. If you clone, modify, install, or redistribute it, you are responsible for reviewing the code and scripts, validating them in your environment, and maintaining your copy. Compatibility with future macOS, Xcode, terminal, or Herdr releases is not guaranteed, and no support, uptime, data-safety, or fitness-for-purpose commitment is implied.

Herdr is a separate project with its own license and maintainers. References to Herdr and supported terminal applications describe interoperability and do not imply endorsement or affiliation.
