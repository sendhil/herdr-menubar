# Persistent widget publishing override

## Problem and decision

On this Mac, `WidgetCenter.shared.currentConfigurations()` reports `HerdrAgents` and
`HerdrRefreshProbe` despite neither appearing in the saved macOS widget layout. The
current publisher trusts those entries and continues its background publication work.
Reported configuration is therefore not reliable evidence of a currently placed widget.

The user chose an explicit Off/Automatic override instead of restarting shared macOS
widget services. No widget preferences or system caches will be cleared or reset.

## User interface and persistence

Add one **Widget Updates** submenu to the existing native menubar menu, next to the
other app settings. It contains mutually exclusive **Off** and **Automatic** choices,
with a checkmark on the saved selection. Use the existing native menu renderer and
system styling; no new window, permission prompt, visual layout, or dependency.

Persist the choice as the app preference `widgetUpdatesEnabled`: false means Off,
true means Automatic. An absent key continues to mean Automatic, preserving the
previous default for existing installations. Set the preference to false on this Mac
as part of the approved installed-app update. Do not change other preferences.

## Publisher lifecycle

- Off prevents both the two-second publication loop and the roughly once-per-minute
  WidgetKit configuration monitor from starting or continuing. It makes no automatic
  WidgetKit configuration queries, activity-file reads, snapshot writes, timeline
  reload requests, or widget-driven Herdr refresh requests.
- Switching Off invalidates publication/tick ownership and cancels the configuration
  and publication tasks. Already-started requests may finish, but late configuration
  replies and refresh results must not reactivate publishing or write snapshots.
- Keep the existing lightweight in-memory cache of the menubar's supervisor events;
  this is not zero bookkeeping. It allows Automatic to publish current session state
  when re-enabled without reconnecting Herdr or creating more connections.
- Automatic retains the current configuration gate and error behavior: query at
  startup and approximately every 60 seconds, publish only if the returned kinds
  contain `HerdrAgents`, and pause on configuration-query errors. The documented
  stale-reporting limitation remains; Off is the authoritative way to disable work.
- Mode changes use the runtime's owned menu-action lifecycle, with obsolete widget
  setting actions cancelled so rapid Off/Automatic selections cannot apply stale
  choices. No asynchronous mode change may restart work after runtime shutdown.

This setting controls agent-widget publication, not normal discovery, status following,
menubar rendering, focus, or notifications. The explicitly launched diagnostic refresh
probe remains independent. No claim is made that the app can prevent macOS from
launching its widget extension for cached system configurations.

## Integration boundaries

- `HerdrMenubar/System/Preferences.swift`: observed, persisted preference.
- `HerdrMenubar/Menu/StatusMenuPresentation.swift`: native submenu and action payload.
- `HerdrMenubar/App/ApplicationRuntime.swift`: startup preference and owned mode changes.
- `HerdrMenubar/Widgets/AgentWidgetPublisher.swift`: mode flag, task cancellation,
  configuration gating and stale-result guards, reusing existing generations/cache.
- Existing XCTest files cover each boundary; `README.md` explains modes and avoids
  promising automatic removal detection when macOS reports stale configurations.

## Verification and installation

Use test-first development to cover default/persisted preferences, menu selection and
native action routing, Off despite ghost configurations, stable query/read/write/reload/
refresh counts while Off, late replies and in-flight ticks, rapid mode changes,
Off-to-Automatic cached-state publication, and shutdown safety. Run the relevant suites
and the broader scoped suite, continuing to report the two independently reproduced
baseline failures rather than claiming an unfiltered green suite.

Install a signed Release using the existing installer and exact current signing identity,
App Group and entitlements. Persist Off before launching the new app. Verify installed
binaries/signatures, unchanged unrelated preferences, one running app, and unchanged
snapshot plus no publication messages for at least 65 seconds. Do not manipulate widgets,
reset global caches, touch earlier client changes, commit, or push without authorization.
