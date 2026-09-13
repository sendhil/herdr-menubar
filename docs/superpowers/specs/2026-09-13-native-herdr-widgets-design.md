# Native Herdr desktop widgets

Date: 2026-09-13
Status: Product direction accepted; implementation and measured freshness pending.
Repository: `/Users/sendhil/src/herdr-menubar`

## Outcome

Add native macOS desktop widgets to Herdr Menubar. A user can place multiple widgets with independent time filters and see the current state of only the agents they personally messaged within that window. Clicking an agent opens its exact Herdr pane through the existing app.

Use the existing repository and application bundle. Add a WidgetKit extension target rather than another independently running application. Keep the Herdr connections in the containing app and share presentation snapshots with the extension through an App Group container.

## Accepted requirements

- Native WidgetKit widgets on the macOS desktop.
- A few seconds of update delay is acceptable; actual latency must be measured.
- Widgets may be hidden behind normal windows for extended periods.
- Filtering is per agent, based on messages sent by the user, not terminal focus, agent output, or general status changes.
- Each widget has an independently configurable time window.
- Only matching agents appear; session groups without matches are hidden.
- Reuse Herdr Menubar for discovery, reconnect handling, login-item lifecycle, and exact-pane navigation.

## Proposed first-release defaults

Use a medium and large list widget, grouped by Herdr session. Show an agent label, textual status with a supplemental status symbol, and the last user-message time. Show a count of additional matches when the family cannot fit every row; do not silently imply the visible rows are the entire result.

Offer Today, Last N hours, Last N days, and All agents. Today means since local midnight in the current timezone. Rolling days mean 24-hour periods. Require positive window lengths. Today is the default. All agents explicitly disables message filtering, including for agents with unknown message history.

Let `t` be the latest confirmed user-message timestamp and `now` the evaluation time. Today includes `startOfDay(now) <= t <= now`. Rolling windows include `now - duration < t <= now`. Agents leave a rolling window at exactly `t + duration`; Today resets at local midnight. Regenerate scheduled boundaries after timezone changes and sleep/wake. Unknown timestamps never qualify for a time-limited view.

Within a session, order agents by last confirmed user message descending, with stable identity as the tie breaker. Order sessions by their newest matching agent. Idle agents remain eligible after completion has been acknowledged. Do not reuse the menu's working/attention-only lists as the widget's source.

These defaults can be refined after the feasibility prototype; the accepted per-agent eligibility semantics remain fixed.

## Evidence collected

The installed CLI reports Herdr 0.7.4. Its exported API schema reports protocol 16. Neither the exported schema nor the inspected live default-session snapshot provides a last-user-message timestamp or a message-submitted event. The API does provide `agent_session` references; the current Swift `PaneInfo` does not decode those references yet.

The default-session snapshot contained ten Pi agents with session-file path references. Two referenced files were inspected for structure only: user messages had entry timestamps and message timestamps. A stored user role is not conclusive proof of human origin, because extensions and API clients can inject messages.

Installed Pi documentation exposes an `input` event with `interactive`, `rpc`, and `extension` source values. The current Herdr Pi extension reports session references and agent state but does not record a last interactive-message timestamp. The activity milestone must verify accepted-submission behavior, including intercepted input and queued messages; observing input before another extension consumes it is not sufficient evidence that a message was sent to the agent.

The machine has macOS 26.6.2 and Xcode 26.6. Herdr Menubar targets macOS 26.0 and currently has empty app entitlements. Its README describes an ad-hoc-signed local installation. Widget embedding, signing, registration, and shared-container access are therefore explicit feasibility checks, not established capabilities of the current build.

Relevant source boundaries:

- `HerdrMenubar/App/ApplicationRuntime.swift`: dependency composition and lifecycle.
- `HerdrMenubar/Herdr/SessionSupervisor.swift`: per-session monitoring.
- `HerdrMenubar/Herdr/APIModels.swift`: snapshots and event decoding.
- `HerdrMenubar/Status/AgentStore.swift`: consumes supervisor events, builds full items, then filters menu presentation.
- `HerdrMenubar/App/HerdrMenubarApp.swift`: application delegate; future URL routing entry point.
- `HerdrMenubar/System/WezTermFocusAdapter.swift`: exact terminal focus behavior.
- `scripts/install.sh`: builds and installs the entire application bundle.

## Architecture

Herdr socket events feed the existing supervisor. A widget snapshot publisher receives complete session snapshots and connection changes before menu-specific filtering. It produces a versioned, bounded, atomically replaced JSON snapshot in the shared container. The WidgetKit extension reads that file; it does not create Herdr socket connections or access transcripts.

Keep the shared model independent of AppKit, menu presentation, and socket transport. Include generation time, a schema version, session-qualified agent identity, labels, status, connection state, and activity provenance. Persist the snapshot as a cache, not as a second authority for Herdr status.

A separate activity store joins confirmed user-message times to agent-session identity. Pane identity alone is insufficient: a replacement agent in a reused pane must not inherit its predecessor's eligibility. Session-file/agent-session references should qualify identity where available. Missing or ambiguous identity produces unknown history rather than a guessed match.

Widget configuration selects a time window. The provider generates the current view and future entries at known expiration boundaries, including midnight, without predicting future agent states. Changes from Herdr cause the containing app to replace the snapshot and request `WidgetCenter` reloads. Coalesce bursts with a fixed upper bound; sustained event traffic must not postpone publication indefinitely. Do not request reloads for unchanged display content.

A widget selection carries exact session and pane identity to the containing app. Reuse the existing validated focus path; stale or missing targets must not fall back to similarly named agents. URL routing and cold-start sequencing belong in the interaction milestone.

## Freshness and failure behavior

Apple documents reload requests, but not a few-second deadline for background menu-bar apps. Foreground budget exemptions do not imply exemption for an app merely remaining alive. A provider callback is also not proof that the desktop has rendered the new content.

Measure three distinct times: data change observed by the app, provider reads that generation, and the generation becomes visible on the desktop. A proposed prototype success threshold is at least 95% of visible-desktop samples displayed within 10 seconds. This operationalizes the user's tolerance; it is not a WidgetKit guarantee. Report sample counts, maximum delay, and delayed or missing samples. Measure return-to-desktop separately because visibility affects scheduling.

On disconnect, retain an explicitly unavailable session state or remove live rows; never leave stale rows labeled as currently working. A missing, corrupt, or unsupported snapshot shows an unavailable view. A stopped or crashed app must not leave its last cache appearing indefinitely live: include an observation time and a timeline transition to an explicit old-snapshot state. Choose the production stale threshold after measuring the feasibility build, rather than masking refresh delays with an arbitrary long timeout.

## Delivery stages

1. **Feasibility:** embedded native widget, shared-container round trip, observable snapshot generation, real refresh measurements with the app in the background. Detailed plan: `../plans/2026-09-13-native-widget-feasibility.md`.
2. **Activity correctness:** Pi-first accepted human-message capture, persistent timestamps with provenance and stable identity, restart/reconnect tests. Do not silently count historical user-role entries or status transitions as human messages. Other agent types require separate source verification.
3. **Product widget:** per-instance window configuration, expiry timelines, session grouping, overflow presentation, idle-agent inclusion, stale-state handling, and exact-pane links.
4. **Finish:** medium/large visual QA in full-color/tinted appearances, accessibility labels, sleep/wake and multi-widget validation, installation documentation.

No general-purpose widget builder, remote-host activity tracking, transcript viewer, or new notification behavior is included.

## Validation

Use hermetic unit tests for snapshot decoding, atomic publication, schema handling, filter boundaries, identity replacement, automated-input exclusion, clock/timezone behavior, and target validation. Use the existing test suite for menu, notification, and shortcut regressions. Integration tests must exercise the actual installed app and widget outside Xcode with WidgetKit developer mode disabled.

Widget registration, App Group access, and visible refresh timing require actual macOS validation. A successful build or preview does not complete the feasibility stage. If measured refreshes do not meet the target, report the observed limitations and retain native widgets as the required surface while revisiting the freshness expectation with the user.

## Sources

- [Apple: Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Apple: WidgetKit foundations, WWDC26](https://developer.apple.com/videos/play/wwdc2026/277/)
- [Apple: Developing a WidgetKit strategy](https://developer.apple.com/documentation/WidgetKit/Developing-a-WidgetKit-strategy)
- Local Pi input documentation: `/Users/sendhil/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/docs/extensions.md`, input-event section.
- Local Herdr Pi integration: `/Users/sendhil/.pi/agent/extensions/herdr-agent-state.ts`.

The API verification files were temporary inspection artifacts; no transcript contents or personal session labels belong in this repository.
