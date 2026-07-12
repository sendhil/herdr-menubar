# Herdr Menubar

Herdr Menubar is a native, menu-bar-only macOS companion for [Herdr](https://herdr.dev). It provides a persistent, glanceable view of coding agents that are working, blocked, or waiting for attention—even when the terminal is behind another application.

Herdr remains the source of truth. The app reads Herdr's public socket API and does not maintain separate agent status or acknowledgement state.

## Features

- Shows a persistent attention count in the macOS menu bar.
- Lists blocked and newly completed agents under **Needs Attention**.
- Shows active agents separately under **Working**.
- Uses Herdr-compatible workspace, tab, and agent labels.
- Focuses the exact Herdr pane when an agent is selected.
- Activates a configurable terminal application after focusing the pane.
- Defaults to WezTerm and discovers supported terminals installed on the Mac.
- Reconnects automatically when Herdr starts, stops, or restarts.
- Supports an optional **Launch at Login** setting.
- Uses a native macOS menu, template icon, accessibility labels, and unified logging.
- Stores preferences only; pane and agent state is never persisted.

## Status behavior

The menu reflects Herdr's semantic pane status:

| Herdr status | Menu behavior |
| --- | --- |
| `blocked` | Appears under **Needs Attention** until the agent can continue. |
| `done` | Appears under **Needs Attention** until Herdr marks the pane as seen. |
| `working` | Appears under **Working**. |
| `idle` | Hidden. |
| `unknown` | Hidden. |

Selecting a row sends `pane.focus` to Herdr. For completed work, Herdr owns the resulting seen-state transition from `done` to `idle`; Herdr Menubar does not acknowledge it independently.

## Requirements

- A current macOS release supported by the project deployment target.
- A running Herdr server or session.
- Xcode 26 or newer, including the macOS SDK and command-line tools. After installing Xcode, select it in **Xcode > Settings > Locations**, or with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- One of the recognized terminal applications for click-through activation. WezTerm is the default.

No Homebrew packages or third-party build tools are required. Signing, notarization, packaged releases, and Homebrew distribution are not currently included.

## Quick Install

Clone the repository, then run this command from the checkout:

```bash
./scripts/install.sh
```

The script makes a Release build using repository-local derived data under `.build/`, installs it as `~/Applications/Herdr Menubar.app`, safely replaces a previous installation, and launches it. It can be invoked from any working directory. To install without launching, use `./scripts/install.sh --no-launch`; `--install-dir DIR` selects a different applications directory.

To update or reinstall, pull the desired source revision and run `./scripts/install.sh` again. The script stops the running app before replacing it, then relaunches the new build.

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
- Retry a disconnected Herdr connection.
- Quit the app.

You can also build from the command line:

```bash
xcodebuild build \
  -project HerdrMenubar.xcodeproj \
  -scheme HerdrMenubar \
  -destination 'platform=macOS'
```

The debug app is written under Xcode's DerivedData directory. When rebuilding while the app is already running, quit or relaunch the existing process so macOS does not continue using a stale binary.

## Herdr connection discovery

Herdr Menubar follows Herdr's public socket path conventions in this order:

1. Non-empty `HERDR_SOCKET_PATH`.
2. Herdr's configuration root from non-empty `XDG_CONFIG_HOME`, otherwise `~/.config`.
3. A named `HERDR_SESSION`, when set to a value other than `default`.
4. The default Herdr socket.

Typical paths are:

```text
~/.config/herdr/herdr.sock
~/.config/herdr/sessions/<name>/herdr.sock
$XDG_CONFIG_HOME/herdr/herdr.sock
$XDG_CONFIG_HOME/herdr/sessions/<name>/herdr.sock
```

`HERDR_SESSION=default` resolves to the root `herdr.sock`, matching Herdr itself.

When disconnected, the icon is dimmed and the menu provides a **Retry** action. The client uses bounded reconnect backoff and rebuilds its authoritative snapshot after reconnecting.

## Terminal activation

Selecting an agent performs the following sequence:

1. Ask Herdr to focus the exact pane.
2. Require a successful Herdr response.
3. Activate the configured terminal through macOS.
4. Refresh the Herdr snapshot.

The app recognizes these terminal bundle identifiers:

- WezTerm
- Ghostty
- iTerm2
- Terminal
- Kitty
- Alacritty

If the configured terminal is unavailable, the menu retains the preference as unavailable and offers installed alternatives.

## Architecture

The app has no third-party dependencies and is split into focused components:

```text
HerdrMenubar/
├── App/       SwiftUI application lifecycle and composition
├── Herdr/     API models, socket discovery, transport, and synchronization
├── Menu/      Menu-bar icon, grouped menu, and agent rows
├── Status/    Observable presentation state and user actions
└── System/    Preferences, terminal activation, logging, and login items
```

The main runtime boundaries are:

- **`HerdrClient`** — an actor that owns socket requests, event subscriptions, snapshots, reconnects, and synchronization generations.
- **`AgentStore`** — a main-actor observable model that derives menu sections and coordinates focus and activation.
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

Actual login-item state is read from macOS through `SMAppService`. Pane snapshots, agent status, terminal output, and Herdr session data are not written to disk by Herdr Menubar.

Runtime diagnostics use the unified logging subsystem `dev.herdr.menubar`. Dynamic socket, server, focus, activation, and error details are logged as private values.

## Current limitations

- Local source build and install workflow only.
- No Developer ID signed or notarized release artifacts; local builds are ad-hoc signed and distributable releases remain future work.
- No automatic updater or package-manager installation.
- Menu presentation intentionally uses native macOS menu behavior rather than a custom dashboard or popover.
- Terminal activation uses a user-selected terminal because Herdr's public API does not currently identify the macOS application hosting an attached client.

## License

No license has been selected for this standalone project yet.
