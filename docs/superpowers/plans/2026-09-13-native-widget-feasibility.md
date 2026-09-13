# Native Widget Feasibility Implementation Plan

Execute this plan inline, task by task. This plan covers the feasibility stage only; do not begin activity tracking or the final widget UI until the refresh results have been assessed.

**Goal:** Install a genuine macOS widget inside Herdr Menubar's app bundle, establish shared snapshot access, and measure background-to-desktop freshness under normal system limits.

**Architecture:** The existing app publishes a small versioned snapshot into an App Group container. An embedded WidgetKit extension reads that snapshot and displays a generation identifier and timestamp. The app requests timeline reloads after publishing changes; measurements distinguish requests, provider reads, and visible renders.

**Tech stack:** Swift, SwiftUI, WidgetKit, Foundation, App Groups, existing Xcode project and XCTest suite.

## Global constraints

- Repository: `/Users/sendhil/src/herdr-menubar`.
- Preserve the existing macOS 26.0 deployment target.
- Native WidgetKit widgets on the macOS desktop.
- A few seconds of update delay is acceptable; actual latency must be measured.
- Reuse the existing app process and Herdr connections.
- Do not introduce agent-message hooks or modify personal agent configuration in this stage.
- Run measurements outside Xcode with WidgetKit developer mode disabled.
- Do not interpret a provider callback as proof of a visible refresh.
- Keep generation IDs and timestamps in measurement output; omit session names, prompts, and transcript contents.
- Complete build artifacts and signing checks before replacing the installed application.

Design: `../specs/2026-09-13-native-herdr-widgets-design.md`.

## Proposed file ownership

| Path relative to repository | Responsibility |
| --- | --- |
| `WidgetShared/WidgetProbeSnapshot.swift` | Foundation-only versioned payload shared by app and extension |
| `WidgetShared/WidgetProbeRepository.swift` | Explicit container URL, atomic JSON writes and reads |
| `HerdrWidgets/HerdrWidgets.swift` | Extension entry, timeline provider, medium-size probe view |
| `HerdrWidgets/Info.plist` | Widget extension declaration |
| `HerdrWidgets/HerdrWidgets.entitlements` | Sandbox and shared App Group entitlement |
| `HerdrMenubar/Widgets/WidgetProbePublisher.swift` | Probe-only timed publication and reload requests |
| `HerdrMenubar/App/ApplicationRuntime.swift` | Own probe lifecycle when explicitly enabled |
| `HerdrMenubar/HerdrMenubar.entitlements` | Shared App Group entitlement |
| `HerdrMenubar.xcodeproj/project.pbxproj` | Shared sources, extension target, dependencies and embedding |
| `HerdrMenubarTests/WidgetProbeRepositoryTests.swift` | Payload round trip and failure behavior |
| `docs/superpowers/experiments/2026-09-13-widget-refresh.md` | Signing/registration evidence and measured results |

No separate package or dependency extraction is required for the probe. Include shared files in both targets through ordinary Xcode target membership.

## Task 1: Establish an embedded, installable widget

**Deliverable:** A medium native desktop widget that displays static probe text from the containing app's installed bundle.

- [ ] Record `git status --short`, the current branch, and available signing configuration. Use an isolated implementation branch; keep the planning commit as its starting point.
- [ ] Run the existing unit suite as the baseline:

```sh
xcodebuild test -project HerdrMenubar.xcodeproj -scheme HerdrMenubar -destination 'platform=macOS' -only-testing:HerdrMenubarTests -derivedDataPath .build/WidgetProbeBaseline
```

- [ ] In Xcode, add a macOS Widget Extension named `HerdrWidgets` to the existing project. Disable configuration intent and Live Activity options for this static probe. Embed it in `HerdrMenubar`; give it a child bundle identifier of the existing app identifier. Preserve deployment target 26.0. Use the generated extension declaration and build phases rather than a standalone application.
- [ ] Replace the generated widget implementation with the following static probe. The next task replaces its hardcoded generation with shared data.

```swift
import SwiftUI
import WidgetKit

struct ProbeEntry: TimelineEntry {
    let date: Date
    let generation: String
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: .now, generation: "Preview")
    }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: .now, generation: "Static probe"))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: .now, generation: "Static probe")], policy: .never))
    }
}

@main
struct HerdrWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HerdrRefreshProbe", provider: ProbeProvider()) { entry in
            VStack(alignment: .leading) {
                Text("Herdr refresh probe").font(.headline)
                Text(entry.generation).monospaced()
                Text(entry.date, style: .time)
            }
            .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Herdr refresh probe")
        .description("Measures native desktop refresh behavior.")
        .supportedFamilies([.systemMedium])
    }
}
```

- [ ] Build Release into `.build/WidgetProbeDerivedData`. Inspect that `HerdrMenubar.app/Contents/PlugIns/HerdrWidgets.appex` exists and verify the app and extension signatures. Record whether existing local signing suffices. If a development team is required, report the precise signing error; do not invent a team identifier or bypass system registration controls.
- [ ] Install the completed bundle using the repository installer and add the native widget through the macOS gallery. Preserve normal app identity and existing preferences. Verify the menu, terminal focus, and probe widget work together.
- [ ] Record the actual signing and registration procedure in the experiment document and commit the installable widget. A build-only result does not satisfy this task.

## Task 2: Publish observable snapshots across processes

**Deliverable:** Background app publication advances the native widget's displayed generation through an App Group snapshot.

**Interfaces:** Shared payload is `WidgetProbeSnapshot`; repository is initialized with an explicit file URL. The app alone writes. Both processes read the same configured App Group container. The publisher owns its cancellation and uses the exact widget kind `HerdrRefreshProbe`.

- [ ] Define the shared model:

```swift
import Foundation

struct WidgetProbeSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generation: UUID
    let writtenAt: Date
}
```

- [ ] Add failing tests using temporary directories. Cover successful round trip and unreadable/malformed data. Do not point tests at the user's App Group.

```swift
func testRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = WidgetProbeRepository(url: directory.appendingPathComponent("probe.json"))
    let snapshot = WidgetProbeSnapshot(schemaVersion: 1, generation: UUID(), writtenAt: Date(timeIntervalSince1970: 100))
    try repository.write(snapshot)
    XCTAssertEqual(try repository.read(), snapshot)
}

func testMalformedPayloadThrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("invalid".utf8).write(to: url)
    XCTAssertThrowsError(try WidgetProbeRepository(url: url).read())
}
```

- [ ] Run the focused test target and confirm failure because the repository is absent. Implement:

```swift
import Foundation

struct WidgetProbeRepository {
    let url: URL

    func write(_ snapshot: WidgetProbeSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    func read() throws -> WidgetProbeSnapshot {
        let snapshot = try JSONDecoder().decode(WidgetProbeSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.schemaVersion == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return snapshot
    }
}
```

- [ ] Add and run the unsupported-schema test, using schema version 2 and expecting a read failure.
- [ ] Configure the same App Group in app and extension using the verified signing setup from Task 1. Resolve its URL with `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`. Treat a nil URL as an explicit unavailable probe state. Do not fall back to an arbitrary home-directory location, because that would not establish shared-container feasibility.
- [ ] Change the provider to read the repository for timeline requests. Display the short generation, snapshot `writtenAt`, and provider-read time. On any read error show `Snapshot unavailable`; never silently substitute a successful-looking preview. Keep preview data limited to gallery previews.
- [ ] Add `WidgetProbePublisher` with an explicit start/stop lifecycle owned by `ApplicationRuntime`. Activate only with launch argument `--widget-refresh-probe`. Its test-only schedule publishes a new UUID every 30 seconds for 30 generations, writes atomically, records the generation and time, then calls `WidgetCenter.shared.reloadTimelines(ofKind: "HerdrRefreshProbe")`. Stop at completion or application shutdown. This is a bounded diagnostic schedule, not the production refresh policy.
- [ ] Log provider-read generation/time in the extension. Keep the ordinary app in the background and confirm the generation advances in the desktop widget. App write failures must be logged and must not be followed by a successful reload measurement.
- [ ] Rebuild, run focused tests plus the existing unit suite, install the verified bundle, and commit the shared snapshot probe.

The App Group identifier is selected from the actual signing setup during execution. Record its exact value in the experiment report; do not assume that ad-hoc signing grants a particular shared-container entitlement.

## Task 3: Measure normal-system freshness and record the decision

**Deliverable:** An evidence-backed result distinguishing proven functionality from unproven latency.

- [ ] Record OS/Xcode version, app build revision, signing mode, power state, WidgetKit developer-mode state, and confirmation that no Xcode debugger is attached.
- [ ] Launch the installed app with `--widget-refresh-probe`. Observe visible generation changes while the app remains in the background. Use a bounded screen recording if available to establish visible timing; do not equate SwiftUI body evaluation or provider logs with screen visibility.
- [ ] Collect at least 30 samples with the desktop widget visible. Record generation, app-write time, provider-read time, visible time, and any missing update. Calculate median, 95th-percentile, and maximum observed write-to-visible delay. Proposed target: at least 95% within 10 seconds. Label the result a sample, not a scheduling guarantee.
- [ ] Repeat after the desktop has been covered for at least 10 minutes. Record time since last actual data change separately from time to catch up after exposing the desktop. Collect at least five return-to-desktop observations over normal use; report incomplete coverage honestly if the session ends first.
- [ ] Check sleep/wake once, quitting/relaunching the app once, and two widget instances once. Record whether a last snapshot remains visible after quit; the probe has no production staleness policy yet.
- [ ] Run a second bounded cadence of five seconds for 30 generations only if the first run demonstrates usable refresh behavior. Compare coalescing and delays with the 30-second run. A faster request cadence must not be reported as a faster observed render cadence.
- [ ] Write the experiment report with sections Environment, Installation, Shared Data, Visible Refresh Results, Hidden Desktop Results, Lifecycle Checks, Limitations, and Recommendation. Include only measurements actually obtained.
- [ ] If static installation or shared-container access fails, report that specific failure and the proven subset. If timing misses the target, report the distribution and the native-widget limitation without switching to custom panels.
- [ ] Disable probe scheduling for ordinary launches, run the relevant unit suite and `xcodebuild analyze`, and commit the measured result. Summarize what is ready for the activity-tracking milestone and what remains uncertain.

## Follow-on boundary

After the feasibility result, write the activity implementation plan around Pi's accepted interactive messages and stable agent-session identity. The source API must be checked for input consumption, queued input, RPC origin, session changes, and extension-injected messages before choosing a hook. Timestamped transcript rows can support historical analysis, but do not automatically establish human provenance. Final configurable UI, expiry timelines, exact-pane deep links, and stale-snapshot presentation belong to the subsequent product milestone.
