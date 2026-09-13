# Native agent widget milestone

Approved scope: extend Herdr Menubar with a real WidgetKit agent list. Each widget has its own message window (Today, last N hours, last N days, or All agents). Only known interactive message timestamps qualify for a time window. Idle agents remain visible if eligible.

## Identity and presentation

Workspace headings, then named tab plus a distinct custom agent name. Numeric default tabs fall back to the custom name or agent type. Multiple unnamed panes in a tab include their pane identifier. Named Herdr sessions prefix the workspace. Rows open the exact session and pane through the app's existing selection path.

Medium and large widgets show a bounded list and an overflow count. The initial configuration is All agents so the installed widget is useful before activity capture starts; choose a message window through Edit Widget.

## Data flow

The host subscribes to SessionSupervisor before discovery starts, retains all agent panes, and coalesces publication on a two-second ticker. Changed rows trigger an atomic App Group snapshot and WidgetCenter reload request. A one-minute heartbeat supports freshness indication. The extension schedules known filter expirations and shows delayed updates after three minutes. macOS controls actual rendering; reload requests do not guarantee a refresh deadline.

The Pi companion records only timestamps and hashes the session path for its local filename. It correlates interactive input with matching delivered user content in memory; old transcripts are never backfilled. Automated input through Pi's input event does not qualify. Transformed/expanded prompts that no longer match remain unknown. This is conservative correlation, not a source field carried by the delivered message: unusual extensions injecting identical content without an input event can be ambiguous. Future upstream provenance support should replace correlation.

## Setup

Install the signed app using scripts/install.sh with the configured signing identity. Copy integrations/pi/herdr-widget-activity.ts into ~/.pi/agent/extensions/. Existing Pi sessions need /reload once; newly started sessions load it automatically. Tracking begins with subsequent matching human messages. Unsupported agent types remain available under All agents but do not qualify for message windows.

Add **Herdr agents** from the native widget gallery (the old refresh probe remains a separate diagnostic widget). Right-click the agent widget and choose Edit Widget to select a window and amount. Days means rolling 24-hour periods; Today follows local calendar midnight.

## Verification

Unit coverage: naming, exact rolling boundary, unknown/future timestamps, local midnight, idle eligibility, URL identity, runtime startup and exact target selection. Bun tests exercise interactive/automated correlation, repeated content, expiration and session resets. Run full app regression tests and a signed Release installation, then inspect published live rows and native rendering. Existing accessibility and process-runner timing failures were recorded before this feature.

### Results

Signed universal Release build and installed app/extension signature checks passed. Live snapshot contained five agents, including Luna Escalation / New Session marked working. Final affected suites: 20 Swift tests passed. Pi suite: five tests, 12 assertions passed, including timestamp-only persistence. Full regression: 409 unit tests, four assertions failed in the same two pre-existing tests (process overflow timing and rendered shortcut accessibility); one UI smoke test passed.

New agent-widget desktop rendering remains unverified: native UI automation selects other widget windows and cannot reliably address the gallery. The earlier refresh-probe widget's rendering was confirmed by the user's screenshot. Actual message capture in an existing live session awaits the user's /reload and subsequent message.
