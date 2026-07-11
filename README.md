# Herdr Menubar

A native macOS menu-bar companion for [Herdr](https://herdr.dev).

Design work is documented in [`docs/superpowers/specs/`](docs/superpowers/specs/).

## Development

Open `HerdrMenubar.xcodeproj` in Xcode and run the `HerdrMenubar` scheme. The app has no Dock icon; use its menu-bar icon to configure the terminal (WezTerm by default), enable Launch at Login, retry the Herdr connection, or quit.

Herdr Menubar follows `HERDR_SOCKET_PATH`, then `HERDR_SESSION`, then `~/.config/herdr/herdr.sock`.
