# SketchyBar integration

Herdr Menubar is the companion app; core Herdr needs no changes. The companion publishes aggregate status without opening another Herdr connection. Widgets and notifications can remain disabled.

Copy `herdr.py` into your SketchyBar plugins directory and add this to `sketchybarrc` (adjust styling to match your theme):

```bash
sketchybar --add event herdr_status_changed dev.herdr.menubar.statusChanged
sketchybar --add item herdr right \
  --set herdr icon='󰆍' label='' label.drawing=off icon.padding_right=8 update_freq=30 \
    script="python3 '$CONFIG_DIR/plugins/herdr.py'" \
    click_script="open 'herdr-menubar://menu'" \
  --subscribe herdr herdr_status_changed system_woke
```

Run `sketchybar --reload`. The badge shows only the icon until agents need attention, then adds their count. Clicking the badge opens the same native menu and routes agent selection through the same session-aware app actions. The regular macOS status item remains available. The popup is positioned near the pointer on its display; opening the URL from a keyboard or terminal uses the current pointer location.

## Status contract (version 1)

`~/Library/Application Support/Herdr Menubar/sketchybar-status.json` contains:

```json
{"schemaVersion":1,"writtenAt":1791840000,"isRunning":true,"mode":"attention","attentionCount":2,"summary":"Connected, 2 agents need attention"}
```

- `writtenAt`: Unix seconds; refreshes on semantic changes and every 30 seconds.
- `mode`: `clear`, `attention`, or `disconnected`, matching the app's status icon.
- `attentionCount`: aggregate attention count, independent of visible workspace.
- `summary`: accessibility description of connection/count, without agent names or terminal content.
- `isRunning`: set false on graceful shutdown. Crashes are detected by freshness.

Writes replace the file atomically with mode 0600 inside a 0700 directory. After each successful write the app posts `dev.herdr.menubar.statusChanged` through macOS DistributedNotificationCenter. It does not launch SketchyBar or require it to be installed. The plugin also refreshes on wake and every 30 seconds; missing, invalid, stopped, or over-90-second-old state renders dimmed. Local files remain inside the user's account.

The URL endpoint accepts exactly `herdr-menubar://menu`. Existing widget agent URLs continue to work. Menu content stays fixed while tracking and updates the next time it opens.

Test the portable plugin with `python3 -m unittest discover -s integrations/sketchybar -v`.
