import AppKit
import Foundation
import XCTest
@testable import HerdrMenubar

/// Spec "Menu", "Badge", "Active backends", and "AgentStore changes → Unavailability": FINISHED
/// with Clear Finished, the `Backend · ` heading prefix, the RECONNECTING backend line, and
/// "No active agents" over all three sections.
@MainActor
final class StatusMenuRexPresentationTests: XCTestCase {
    func testFinishedSectionSitsBetweenAttentionAndWorkingAndEndsWithClearFinished() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.herdr.send(.discovery([]))   // both backends active: headings carry the prefix
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexBlocked, rexDone, rexWorking], attention: [])))
        await fixture.waitUntil { fixture.store.workingSections.count == 1 }

        let menu = fixture.presentation().menu
        XCTAssertEqual(Array(menu.prefix(13)), [
            .heading("NEEDS ATTENTION"),
            .heading("REX · FIX-PLAYBACK"),
            .agent(title: "Playback · pi", subtitle: "blocked · Allow rm -rf build?",
                   symbol: "exclamationmark.triangle.fill", quieter: false, target: target(rexBlocked)),
            .separator,
            .heading("FINISHED"),
            .heading("REX · FIX-PLAYBACK"),
            .agent(title: "Review · claude-code", subtitle: "done · claude-code",
                   symbol: "checkmark.circle.fill", quieter: false, target: target(rexDone)),
            .action(title: "Clear Finished", state: .off, isEnabled: true, action: .clearFinished),
            .separator,
            .heading("WORKING"),
            .heading("REX · FIX-PLAYBACK"),
            .agent(title: "Design · claude-code", subtitle: "working · claude-code",
                   symbol: "ellipsis.circle", quieter: true, target: target(rexWorking)),
            .separator
        ])
        XCTAssertFalse(menu.contains(.info("No active agents", tone: .secondary)))
        await fixture.stop()
    }

    func testErrorRowUsesOctagonSymbolInNeedsAttention() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexError], attention: [])))
        await fixture.waitUntil { fixture.store.attentionCount == 1 }

        XCTAssertEqual(fixture.presentation().menu.prefix(3).last, .agent(
            title: "Build", subtitle: "error · exit 1", symbol: "xmark.octagon", quieter: false,
            target: target(rexError)
        ))
        await fixture.stop()
    }

    func testFinishedOnlyIsNotNoActiveAgentsAndClearFinishedHiddenWhenEmpty() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.herdr.send(.discovery([herdrWork]))
        fixture.herdr.send(.connected(herdrWork, .empty))
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexDone], attention: [])))
        await fixture.waitUntil { fixture.store.finishedSections.count == 1 && fixture.store.connectionState == .connected }

        var menu = fixture.presentation().menu
        XCTAssertEqual(menu.first, .heading("FINISHED"))
        XCTAssertFalse(menu.contains(.info("No active agents", tone: .secondary)))

        fixture.rex.send(.snapshot(rexFix.key, .empty))
        await fixture.waitUntil { fixture.store.finishedSections.isEmpty }
        menu = fixture.presentation().menu
        XCTAssertEqual(menu.first, .info("No active agents", tone: .secondary))
        XCTAssertFalse(menu.contains(.heading("FINISHED")))
        XCTAssertFalse(menu.contains(.action(title: "Clear Finished", state: .off, isEnabled: true, action: .clearFinished)))
        await fixture.stop()
    }

    func testRexErrorWithFinishedRowsLabelsClearFinishedAndFailedAtEndOfFinished() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexError, rexDone], attention: [])))
        await fixture.waitUntil { fixture.store.finishedSections.count == 1 && fixture.store.attentionCount == 1 }

        let menu = fixture.presentation().menu
        XCTAssertEqual(Array(menu.prefix(8)), [
            .heading("NEEDS ATTENTION"),
            .heading("FIX-PLAYBACK"),
            .agent(title: "Build", subtitle: "error · exit 1", symbol: "xmark.octagon", quieter: false,
                   target: target(rexError)),
            .separator,
            .heading("FINISHED"),
            .heading("FIX-PLAYBACK"),
            .agent(title: "Review · claude-code", subtitle: "done · claude-code",
                   symbol: "checkmark.circle.fill", quieter: false, target: target(rexDone)),
            .action(title: "Clear Finished and Failed", state: .off, isEnabled: true, action: .clearFinished),
        ])
        XCTAssertEqual(clearItems(menu).count, 1)
        await fixture.stop()
    }

    func testRexErrorWithoutFinishedRowsPlacesClearFinishedAndFailedAtEndOfNeedsAttention() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexBlocked, rexError], attention: [])))
        await fixture.waitUntil { fixture.store.attentionCount == 2 }

        let menu = fixture.presentation().menu
        XCTAssertEqual(Array(menu.prefix(6)), [
            .heading("NEEDS ATTENTION"),
            .heading("FIX-PLAYBACK"),
            .agent(title: "Playback · pi", subtitle: "blocked · Allow rm -rf build?",
                   symbol: "exclamationmark.triangle.fill", quieter: false, target: target(rexBlocked)),
            .agent(title: "Build", subtitle: "error · exit 1", symbol: "xmark.octagon", quieter: false,
                   target: target(rexError)),
            .action(title: "Clear Finished and Failed", state: .off, isEnabled: true, action: .clearFinished),
            .separator,
        ])
        XCTAssertFalse(menu.contains(.heading("FINISHED")))
        XCTAssertEqual(clearItems(menu).count, 1)
        await fixture.stop()
    }

    func testFinishedOnlyKeepsTheClearFinishedLabel() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexBlocked, rexDone], attention: [])))
        await fixture.waitUntil { fixture.store.finishedSections.count == 1 }

        let menu = fixture.presentation().menu
        XCTAssertEqual(clearItems(menu), [
            .action(title: "Clear Finished", state: .off, isEnabled: true, action: .clearFinished)
        ])
        let index = menu.firstIndex(of: .heading("FINISHED"))!
        XCTAssertEqual(menu[index + 3], clearItems(menu)[0], "still the last item of FINISHED")
        await fixture.stop()
    }

    func testBlockedOnlyAttentionHasNoClearItem() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexBlocked, rexWorking], attention: [])))
        await fixture.waitUntil { fixture.store.attentionCount == 1 && fixture.store.workingSections.count == 1 }

        XCTAssertEqual(clearItems(fixture.presentation().menu), [])
        await fixture.stop()
    }

    func testNonRexErrorRowDoesNotShowTheClearItem() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.herdr.send(.discovery([herdrWork]))
        fixture.herdr.send(.connected(herdrWork, BackendSnapshot(rows: [herdrError], attention: [])))
        await fixture.waitUntil { fixture.store.attentionCount == 1 }

        XCTAssertEqual(clearItems(fixture.presentation().menu), [])
        await fixture.stop()
    }

    func testDetachedMenuShowsTheSameClearFinishedAndFailedNodes() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexError], attention: [])))
        await fixture.waitUntil { fixture.store.attentionCount == 1 }
        let presentation = fixture.presentation()

        var shown: [[StatusMenuNode]] = []
        var detachedActions: [StatusMenuAction] = []
        let detached = DetachedMenuController(
            show: { nodes, action in shown.append(nodes); action(.clearFinished) },
            cancel: {},
            action: { detachedActions.append($0) }
        )
        detached.apply(presentation)
        detached.show()
        XCTAssertEqual(shown, [presentation.menu])
        XCTAssertEqual(clearItems(shown[0]).map(\.actionTitle), ["Clear Finished and Failed"])
        XCTAssertEqual(detachedActions, [.clearFinished])
        await fixture.stop()
    }

    func testBadgeAccessibilityAndSketchyBarExcludeRexDone() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexBlocked, rexError, rexDone], attention: [])))
        await fixture.waitUntil { fixture.store.finishedSections.count == 1 && fixture.store.connectionState == .connected }

        let presentation = fixture.presentation()
        XCTAssertEqual(presentation.icon, MenuBarIconPresentation(connectionState: .connected, attentionCount: 2, wording: .agents))
        XCTAssertEqual(presentation.accessibilityValue, MenuBarIcon.accessibilityValue(
            connectionState: .connected, attentionCount: 2, wording: .agents
        ))

        var written: [SketchyBarSnapshot] = []
        let publisher = SketchyBarStatusPublisher(now: { 1 }, write: { written.append($0) }, notify: {}, automaticHeartbeat: false)
        publisher.start()
        publisher.apply(presentation)
        XCTAssertEqual(written.last?.attentionCount, 2)
        XCTAssertEqual(written.last?.mode, "attention")

        fixture.rex.send(.snapshot(rexFix.key, BackendSnapshot(rows: [rexDone], attention: [])))
        await fixture.waitUntil { fixture.store.attentionCount == 0 }
        publisher.apply(fixture.presentation())
        XCTAssertEqual(written.last?.attentionCount, 0)
        XCTAssertEqual(written.last?.mode, "clear")
        publisher.stop()
        await fixture.stop()
    }

    func testBackendPrefixOnlyWithMoreThanOneActiveBackend() async {
        // Rex not yet active: Herdr headings exactly as today.
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.herdr.send(.discovery([herdrWork]))
        fixture.herdr.send(.connected(herdrWork, BackendSnapshot(rows: [herdrWorking], attention: [])))
        await fixture.waitUntil { fixture.store.workingSections.count == 1 }
        XCTAssertTrue(fixture.presentation().menu.contains(.heading("WORK")))

        // Rex active (even with zero sessions): every heading gains its backend prefix.
        fixture.rex.send(.discovery([]))
        await fixture.waitUntil { fixture.store.activeBackends.contains(.rex) }
        XCTAssertTrue(fixture.presentation().menu.contains(.heading("HERDR · WORK")))
        XCTAssertFalse(fixture.presentation().menu.contains(.heading("WORK")))

        // Hidden again: back to today's headings.
        fixture.rex.send(.backendHidden)
        await fixture.waitUntil { !fixture.store.activeBackends.contains(.rex) }
        XCTAssertTrue(fixture.presentation().menu.contains(.heading("WORK")))
        await fixture.stop()
    }

    func testNoPrefixWhileHerdrIsEnabledButHasNotDiscovered() async {
        // "Active" means emitted `.discovery` this run; merely enabling Herdr does not count.
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexWorking], attention: [])))
        await fixture.waitUntil { fixture.store.workingSections.count == 1 }

        XCTAssertFalse(fixture.store.showsBackendPrefix)
        XCTAssertTrue(fixture.presentation().menu.contains(.heading("FIX-PLAYBACK")))

        fixture.herdr.send(.discovery([herdrWork]))
        await fixture.waitUntil { fixture.store.activeBackends.contains(.herdr) }
        XCTAssertTrue(fixture.presentation().menu.contains(.heading("REX · FIX-PLAYBACK")))
        await fixture.stop()
    }

    func testRexOnlyEnabledHasNoPrefix() async {
        let fixture = RexPresentationFixture(enabledBackends: ["rex"])
        await fixture.start()
        fixture.rex.send(.discovery([rexFix]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexWorking], attention: [])))
        await fixture.waitUntil { fixture.store.workingSections.count == 1 }

        XCTAssertTrue(fixture.presentation().menu.contains(.heading("FIX-PLAYBACK")))
        await fixture.stop()
    }

    func testRexOutageShowsOneReconnectingLineWithReasonTooltipAndRetry() async throws {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.herdr.send(.discovery([herdrWork]))
        fixture.herdr.send(.connected(herdrWork, .empty))
        fixture.herdr.send(.sessionUnavailable(herdrWork.key, "socket unavailable"))
        fixture.rex.send(.discovery([rexFix, rexOther]))
        fixture.rex.send(.connected(rexFix, BackendSnapshot(rows: [rexBlocked], attention: [])))
        fixture.rex.send(.connected(rexOther, .empty))
        fixture.rex.send(.backendUnavailable("Rex watcher stopped sending heartbeats"))
        await fixture.waitUntil { fixture.store.unavailableBackends[.rex] != nil && fixture.store.unavailableSessions.count == 1 }

        let menu = fixture.presentation().menu
        let index = try XCTUnwrap(menu.firstIndex(of: .heading("RECONNECTING")))
        XCTAssertEqual(Array(menu[index...].prefix(3)), [
            .heading("RECONNECTING"),
            .info("work", tone: .secondary),
            .info("Rex", tone: .secondary, toolTip: "Rex watcher stopped sending heartbeats")
        ])
        XCTAssertEqual(menu.filter { $0 == .heading("RECONNECTING") }.count, 1)
        XCTAssertTrue(menu.contains(.action(
            title: "Retry Unavailable Sessions", state: .off, isEnabled: true, action: .retryUnavailable
        )))
        await fixture.stop()
    }

    func testRexOutageAloneShowsRetryAndRecoveryRemovesTheLine() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.rex.send(.discovery([]))
        fixture.rex.send(.backendUnavailable("Rex is not running"))
        await fixture.waitUntil { fixture.store.unavailableBackends[.rex] != nil }

        var menu = fixture.presentation().menu
        XCTAssertTrue(menu.contains(.info("Rex", tone: .secondary, toolTip: "Rex is not running")))
        XCTAssertTrue(menu.contains(.action(
            title: "Retry Unavailable Sessions", state: .off, isEnabled: true, action: .retryUnavailable
        )))

        fixture.rex.send(.discovery([]))
        await fixture.waitUntil { fixture.store.unavailableBackends.isEmpty }
        menu = fixture.presentation().menu
        XCTAssertFalse(menu.contains(.heading("RECONNECTING")))
        XCTAssertFalse(menu.contains(.action(
            title: "Retry Unavailable Sessions", state: .off, isEnabled: true, action: .retryUnavailable
        )))
        await fixture.stop()
    }

    func testOutageOfABackendThatWasNeverActiveShowsNothing() async {
        let fixture = RexPresentationFixture()
        await fixture.start()
        fixture.herdr.send(.discovery([]))
        fixture.rex.send(.backendUnavailable("Rex is not running"))
        await fixture.waitUntil {
            fixture.store.unavailableBackends[.rex] != nil && fixture.store.connectionState == .noSessions
        }

        let menu = fixture.presentation().menu
        XCTAssertFalse(menu.contains(.heading("RECONNECTING")))
        XCTAssertFalse(menu.contains(.action(
            title: "Retry Unavailable Sessions", state: .off, isEnabled: true, action: .retryUnavailable
        )))
        XCTAssertEqual(menu.first, .info("No Herdr sessions running", tone: .secondary))
        await fixture.stop()
    }

    func testStoreClearFinishedCallsEveryEnabledBackend() async {
        let fixture = RexPresentationFixture()
        await fixture.start()

        await fixture.store.clearFinished()

        XCTAssertEqual(fixture.rex.calls, ["start", "clearFinished"])
        XCTAssertEqual(fixture.herdr.calls, ["start", "clearFinished"])
        await fixture.stop()
    }

    func testStoreClearFinishedSkipsDisabledBackends() async {
        let fixture = RexPresentationFixture(enabledBackends: ["herdr"])
        await fixture.start()

        await fixture.store.clearFinished()

        XCTAssertFalse(fixture.rex.calls.contains("clearFinished"))
        await fixture.stop()
    }

    func testRendererSetsInfoToolTipAndDetachedMenuShowsTheSameNodes() {
        let nodes: [StatusMenuNode] = [
            .heading("FINISHED"),
            .action(title: "Clear Finished", state: .off, isEnabled: true, action: .clearFinished),
            .heading("RECONNECTING"),
            .info("Rex", tone: .secondary, toolTip: "watcher exited"),
            .info("work", tone: .secondary)
        ]
        var performed: [StatusMenuAction] = []
        let renderer = NativeStatusMenuRenderer(action: { performed.append($0) })
        let menu = renderer.makeMenu(nodes)
        XCTAssertEqual(menu.items[3].title, "Rex")
        XCTAssertEqual(menu.items[3].toolTip, "watcher exited")
        XCTAssertNil(menu.items[4].toolTip)
        XCTAssertTrue(menu.items[1].isEnabled)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(performed, [.clearFinished])

        var shown: [[StatusMenuNode]] = []
        var detachedActions: [StatusMenuAction] = []
        let detached = DetachedMenuController(
            show: { nodes, action in shown.append(nodes); action(.clearFinished) },
            cancel: {},
            action: { detachedActions.append($0) }
        )
        detached.apply(StatusItemPresentation(
            icon: MenuBarIconPresentation(connectionState: .connected, attentionCount: 0, wording: .agents),
            accessibilityValue: "",
            menu: nodes
        ))
        detached.show()
        XCTAssertEqual(shown, [nodes])
        XCTAssertEqual(detachedActions, [.clearFinished])
    }
}

// MARK: - Fixtures

private let rexFixKey = AgentSessionKey(backend: .rex, rawID: "s1")
private let rexFix = AgentSessionDescriptor(key: rexFixKey, displayName: "fix-playback")
private let rexOther = AgentSessionDescriptor(key: AgentSessionKey(backend: .rex, rawID: "s2"), displayName: "other")
private let herdrWork = AgentSessionDescriptor(key: .named("work"), displayName: "work")

private func rexRow(_ pane: String, _ label: String, _ agent: String?, _ state: RowState, _ subtitle: String) -> AgentRow {
    AgentRow(target: AgentTarget(session: rexFixKey, paneID: pane), displayLabel: label, agentLabel: agent,
             state: state, subtitle: subtitle, seenToken: nil)
}

private let rexBlocked = rexRow("b1", "Playback", "pi", .attention(.blocked), "blocked · Allow rm -rf build?")
private let rexError = rexRow("b4", "Build", nil, .attention(.error), "error · exit 1")
private let rexDone = rexRow("b2", "Review", "claude-code", .finished, "done · claude-code")
private let rexWorking = rexRow("b3", "Design", "claude-code", .working, "working · claude-code")
private let herdrError = AgentRow(
    target: AgentTarget(session: .named("work"), paneID: "p2"), displayLabel: "api", agentLabel: "claude",
    state: .attention(.error), subtitle: "error", seenToken: nil
)
private let herdrWorking = AgentRow(
    target: AgentTarget(session: .named("work"), paneID: "p1"), displayLabel: "api", agentLabel: "claude",
    state: .working, subtitle: "working · claude", seenToken: nil
)

private func clearItems(_ menu: [StatusMenuNode]) -> [StatusMenuNode] {
    menu.filter { if case .action(_, _, _, .clearFinished) = $0 { true } else { false } }
}

private extension StatusMenuNode {
    var actionTitle: String? {
        if case .action(let title, _, _, _) = self { title } else { nil }
    }
}

private func target(_ row: AgentRow) -> SelectionTarget {
    SelectionTarget(target: row.target, sessionDisplayName: "fix-playback")
}

@MainActor
final class RexPresentationFixture {
    let herdr = FakeAgentBackend(kind: .herdr)
    let rex = FakeAgentBackend(kind: .rex)
    let preferences: Preferences
    let store: AgentStore
    let notifications: NotificationSettingsController
    let login = RexPresentationLoginItem()

    init(enabledBackends: [String] = ["herdr", "rex"]) {
        let suite = "dev.herdr.menubar.rex-presentation-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(enabledBackends, forKey: Preferences.enabledBackendsKey)
        preferences = Preferences(defaults: defaults)
        let service = BackendStoreNotifications()
        notifications = NotificationSettingsController(service: service, preferences: preferences)
        store = AgentStore(
            backends: [herdr, rex],
            attentionCoordinator: BackendStoreCoordinator(),
            notificationService: service,
            preferences: preferences
        )
    }

    func presentation() -> StatusItemPresentation {
        StatusMenuPresentationBuilder().make(
            store: store, preferences: preferences, terminals: [], loginItem: login, notifications: notifications
        )
    }

    func start() async { await store.start() }
    func stop() async { await store.stop() }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class RexPresentationLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var isEnabled: Bool { false }
    var isChanging: Bool { false }
    var helpText: String? { nil }
    var errorMessage: String? { nil }
    func refreshStatus() {}
    func setEnabled(_ enabled: Bool) async throws {}
}
