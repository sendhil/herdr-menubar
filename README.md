# Herdr Menubar

A native macOS menu-bar companion for [Herdr](https://herdr.dev).

Design work is documented in [`docs/superpowers/specs/`](docs/superpowers/specs/).

## Development

Open `HerdrMenubar.xcodeproj` in Xcode and run the `HerdrMenubar` scheme. The app has no Dock icon; use its menu-bar icon to configure the terminal (WezTerm by default), enable Launch at Login, retry the Herdr connection, or quit.

Herdr Menubar follows `HERDR_SOCKET_PATH`; otherwise it uses the Herdr config root at `$XDG_CONFIG_HOME/herdr` or `~/.config/herdr`, with `HERDR_SESSION` selecting a named session socket below that root.
