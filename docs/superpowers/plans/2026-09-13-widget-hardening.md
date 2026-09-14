# Widget reliability and visual refresh implementation plan

The user approved all findings and the recommended workspace design in the independent review. Continue in the existing isolated native-widget-prototype worktree. No additional design approval is needed.

Goal: prevent false human attribution and silent staleness, make upgrades repeatable, and give native widgets clearer hierarchy in every rendering mode.

Architecture: preserve the shared snapshot boundary and WidgetKit configuration. Keep message capture conservative, extract deterministic timeline planning, expose verified source health separately from publication time, and use family-specific presentation budgets. The host and extension must both retain configuration metadata.

## Work packages

- [x] Pi capture (correctness agent): reproduce automated/human identical queue ordering; retain overlapping hashes as ambiguous, remove the arbitrary two-hour expiration without allowing silent memory eviction to become positive evidence; cover long queues, repeated messages, session reset and persistence. Own integrations/pi only.
- [x] Source health and publisher (reliability agent): add bounded periodic source reconciliation using existing Herdr APIs, lifecycle-safe retries, injectable publisher dependencies and targeted tests. Preserve idle eligibility. Own publisher/source integration and its tests; coordinate schema with parent.
- [x] Visual refresh (visual agent): workspace-focused large widget, compact contextual medium rows, derived status summary, shape-plus-text statuses, semantic tint-safe styling, concrete age footer, layout budgets and accessibility. Own view/presentation files and their tests, not provider/configuration.
- [x] Timeline safety (parent): reproduce32 expirations crowding out stale transition; extract pure planner; reserve mandatory transitions and expire conservatively beyond a bounded horizon; test multiple configurations, midnight and stale deadlines.
- [x] Upgrade verification (parent): stop exact installed host/extension processes, validate matching build versions and both configuration metadata bundles, refresh only the installed app registration, verify signatures, preserve configured widgets. Test scripts with isolated fixtures/stubs.
- [x] Integration (parent): register new source/test files once workers complete, run affected tests then full regression once, render actual SwiftUI views for large/medium and tint-like contrast, build signed release with incremented coordinated version, install companion and app, verify fresh published data and repeated successful native loads. Document any manual sleep/wake/visible-presentation checks that cannot be completed unattended.

## Constraints and validation

No global widget cache/LaunchServices resets, no unrelated changes, no machine sleep or agent messages used as synthetic tests. Do not register development builds during worker test runs. Parent controls Xcode project, build versions, Xcode builds, installation and git commits. Tests for deterministic logic can run as standalone Swift/Bun without app registration. Every bug fix begins with a reproducing test. Prefer real source requests and temporary files over implementation-mirroring mocks.


## Results

All five review findings and the recommended visual direction implemented. Additional regressions cover clock rollback, source-health warnings on filtered-empty widgets, and already-absent development registrations.

- Final targeted Swift run:34 tests passed. Pi capture:14 tests/32 assertions passed. Installer fixtures:30 passed, including exact -10814 absence handling and fatal handling of other errors.
- Full Swift run before the final three clock/source tests:421 tests, four failing assertions in the same two pre-existing tests (BoundedProcessRunner overflow timing and rendered shortcut accessibility). No new failures; affected suites were rerun after final corrections.
- Build4 Release installed using the completed installer, with both signatures and both AppIntent metadata bundles validated. Existing large-widget identity/configuration survived; NotificationCenter logged repeated successful loads after upgrade through20:18:50. Spot-check snapshot age1.5s, source verification age1.8s, six agents.
- Actual SwiftUI content rendered at native medium/large dimensions in light/dark, dense/long-name, and stale-empty scenarios. Preview files under .build/WidgetVisuals. This verifies content layout, not pixel-identical macOS desktop tint rendering.
- Updated Pi companion copied to ~/.pi/agent/extensions/herdr-widget-activity.ts. Existing sessions require /reload to load it; capture cannot change already-running extension code automatically.

Sleep/wake and hour-long unattended observation remain unverified. No machine sleep or synthetic messages were sent to active agents. Unit tests cover publisher lifecycle, disconnected source, retry, bounded reconciliation, timeline safety and clock rollback; real upgrade and repeated loads were exercised. The prior installed-app backup from the deliberately failed registration run remains at ~/Applications/.Herdr Menubar.app.backup.13607.
