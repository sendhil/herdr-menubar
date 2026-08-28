import AppKit
import XCTest
@testable import HerdrMenubar

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testStartInstallsExactlyOneStatusItem() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }

        controller.start()
        controller.start()

        XCTAssertEqual(driver.installCount, 1)
        XCTAssertTrue(driver.delegate === controller)
    }

    func testClosedApplyUpdatesExactIconAndRebuildsMenuImmediately() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        let snapshot = presentation(7, node: .heading("SEVEN"))
        controller.start()

        controller.apply(snapshot)

        XCTAssertEqual(driver.iconApplications, [IconApplication(
            presentation: snapshot.icon,
            accessibilityValue: "snapshot 7"
        )])
        XCTAssertEqual(snapshot.icon.attentionCount, 7)
        XCTAssertEqual(driver.menuReplacements, [[.heading("SEVEN")]])
    }

    func testTrackedApplyUpdatesIconButDefersStructuralReplacement() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        let initial = presentation(1, node: .heading("INITIAL"))
        let tracked = presentation(2, node: .heading("TRACKED"))
        controller.start()
        controller.apply(initial)
        driver.simulateMenuWillOpen()
        let replacementsBeforeTrackedApply = driver.menuReplacements

        controller.apply(tracked)

        XCTAssertEqual(driver.iconApplications.last, IconApplication(
            presentation: tracked.icon,
            accessibilityValue: "snapshot 2"
        ))
        XCTAssertEqual(driver.menuReplacements, replacementsBeforeTrackedApply)
    }

    func testMenuWillOpenAppliesNewestSnapshotBeforeTrackingBegins() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        let newest = presentation(3, node: .heading("NEWEST"))
        controller.start()
        controller.apply(presentation(1, node: .heading("OLD")))
        controller.apply(newest)

        driver.simulateMenuWillOpen()

        XCTAssertEqual(driver.menuReplacements.last, newest.menu)
        controller.toggle()
        XCTAssertEqual(driver.cancelTrackingCount, 1)
        XCTAssertEqual(driver.performClickCount, 0)
    }

    func testMenuDidCloseAppliesNewestChangeReceivedDuringTracking() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        let newest = presentation(4, node: .heading("DURING TRACKING"))
        controller.start()
        controller.apply(presentation(1, node: .heading("INITIAL")))
        driver.simulateMenuWillOpen()
        controller.apply(presentation(2, node: .heading("OLDER TRACKED")))
        controller.apply(newest)

        driver.simulateMenuDidClose()

        XCTAssertEqual(driver.menuReplacements.last, newest.menu)
        controller.toggle()
        XCTAssertEqual(driver.performClickCount, 1)
        XCTAssertEqual(driver.cancelTrackingCount, 0)
    }

    func testClosedTogglePerformsOneSupportedButtonClick() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        controller.start()

        controller.toggle()

        XCTAssertEqual(driver.performClickCount, 1)
        XCTAssertEqual(driver.cancelTrackingCount, 0)
    }

    func testOpenToggleCancelsTrackingOnce() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        controller.start()
        driver.simulateMenuWillOpen()

        controller.toggle()

        XCTAssertEqual(driver.performClickCount, 0)
        XCTAssertEqual(driver.cancelTrackingCount, 1)
    }

    func testMouseOpenThenShortcutCloseReconcilesFromDelegateCallbacks() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        controller.start()

        driver.simulateMenuWillOpen()
        controller.toggle()
        driver.simulateMenuDidClose()
        controller.toggle()

        XCTAssertEqual(driver.cancelTrackingCount, 1)
        XCTAssertEqual(driver.performClickCount, 1)
    }

    func testShortcutOpenThenMouseDismissReconcilesFromDelegateCallbacks() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        controller.start()

        controller.toggle()
        driver.simulateMenuWillOpen()
        driver.simulateMenuDidClose()
        controller.toggle()

        XCTAssertEqual(driver.performClickCount, 2)
        XCTAssertEqual(driver.cancelTrackingCount, 0)
    }

    func testRapidTogglesFollowDelegateStateInsteadOfInferringClickParity() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        controller.start()

        controller.toggle()
        controller.toggle()
        XCTAssertEqual(driver.performClickCount, 2)
        XCTAssertEqual(driver.cancelTrackingCount, 0)

        driver.simulateMenuWillOpen()
        controller.toggle()
        controller.toggle()
        XCTAssertEqual(driver.performClickCount, 2)
        XCTAssertEqual(driver.cancelTrackingCount, 2)

        driver.simulateMenuDidClose()
        controller.toggle()
        XCTAssertEqual(driver.performClickCount, 3)
    }

    func testReplacementActionRoutesStableTokenUnchanged() {
        let driver = FakeStatusItemDriver()
        var received: [StatusMenuAction] = []
        let controller = StatusItemController(driver: driver) { received.append($0) }
        let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "pane-2")
        controller.start()
        controller.apply(presentation(1, node: .agent(
            title: "Renamable", subtitle: "blocked", symbol: "triangle", quieter: false,
            target: target
        )))

        driver.invokeLatestAction(.select(target))

        XCTAssertEqual(received, [.select(target)])
    }

    func testStopCancelsRemovesAndRejectsLateCallbacksAndSnapshots() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }
        controller.start()
        controller.apply(presentation(1, node: .heading("BEFORE")))

        controller.stop()
        controller.stop()
        driver.simulateMenuWillOpen()
        driver.simulateMenuDidClose()
        controller.apply(presentation(2, node: .heading("AFTER")))
        controller.toggle()
        controller.start()

        XCTAssertEqual(driver.cancelTrackingCount, 1)
        XCTAssertEqual(driver.removeCount, 1)
        XCTAssertEqual(driver.installCount, 1)
        XCTAssertEqual(driver.menuReplacements.last, [.heading("BEFORE")])
        XCTAssertEqual(driver.performClickCount, 0)
    }

    func testStopBeforeStartPermanentlyRejectsInstallationAndSnapshots() {
        let driver = FakeStatusItemDriver()
        let controller = StatusItemController(driver: driver) { _ in }

        controller.stop()
        controller.apply(presentation(2, node: .heading("LATE")))
        controller.start()
        controller.toggle()

        XCTAssertEqual(driver.installCount, 0)
        XCTAssertEqual(driver.iconApplications, [])
        XCTAssertEqual(driver.menuReplacements, [])
        XCTAssertEqual(driver.performClickCount, 0)
    }

    func testNativeRendererMapsEveryNodeAndDispatchesRepresentedActionTokens() throws {
        let target = NotificationSelectionTarget(sessionID: .named("work"), paneID: "p2")
        let nodes: [StatusMenuNode] = [
            .heading("HEADING"),
            .agent(
                title: "Agent", subtitle: "blocked · Claude",
                symbol: "exclamationmark.triangle.fill", quieter: true, target: target
            ),
            .info("Secondary", tone: .secondary),
            .info("Failure", tone: .error),
            .toggle(
                title: "Sound", isOn: true, isEnabled: false,
                action: .setSound(false)
            ),
            .submenu(title: "Terminal", children: [
                .action(
                    title: "WezTerm", state: .mixed, isEnabled: true,
                    action: .selectTerminal("com.github.wez.wezterm")
                )
            ]),
            .action(
                title: "Retry", state: .off, isEnabled: true,
                action: .retryUnavailable
            ),
            .separator
        ]
        var received: [StatusMenuAction] = []
        let renderer = NativeStatusMenuRenderer { received.append($0) }

        let menu = renderer.makeMenu(nodes)

        XCTAssertEqual(menu.items.count, 8)
        XCTAssertFalse(menu.autoenablesItems)
        assertDisabledTextItem(menu.items[0], title: "HEADING", color: .secondaryLabelColor)
        XCTAssertEqual(menu.items[0].indentationLevel, 0)

        let agent = menu.items[1]
        XCTAssertEqual(agent.title, "Agent")
        XCTAssertEqual(agent.subtitle, "blocked · Claude")
        XCTAssertEqual(agent.image?.accessibilityDescription, "Agent status")
        XCTAssertEqual(agent.indentationLevel, 1)
        XCTAssertTrue(agent.isEnabled)
        XCTAssertEqual(action(in: agent), .select(target))
        XCTAssertEqual(agent.attributedTitle?.attribute(
            .foregroundColor, at: 0, effectiveRange: nil
        ) as? NSColor, .secondaryLabelColor)

        assertDisabledTextItem(menu.items[2], title: "Secondary", color: .secondaryLabelColor)
        assertDisabledTextItem(menu.items[3], title: "Failure", color: .systemRed)

        let toggle = menu.items[4]
        XCTAssertEqual(toggle.title, "Sound")
        XCTAssertEqual(toggle.state, .on)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(action(in: toggle), .setSound(false))

        let terminal = menu.items[5]
        XCTAssertEqual(terminal.title, "Terminal")
        XCTAssertNil(terminal.representedObject)
        let terminalChoice = try XCTUnwrap(terminal.submenu?.items.first)
        XCTAssertFalse(try XCTUnwrap(terminal.submenu).autoenablesItems)
        XCTAssertEqual(terminalChoice.state, .mixed)
        XCTAssertTrue(terminalChoice.isEnabled)
        XCTAssertEqual(
            action(in: terminalChoice),
            .selectTerminal("com.github.wez.wezterm")
        )

        let retry = menu.items[6]
        XCTAssertEqual(retry.state, .off)
        XCTAssertEqual(action(in: retry), .retryUnavailable)
        XCTAssertTrue(menu.items[7].isSeparatorItem)

        let actionableItems = actionableItems(in: menu)
        XCTAssertEqual(actionableItems, [agent, toggle, terminalChoice, retry])
        for item in actionableItems {
            XCTAssertEqual(item.action, #selector(NativeStatusMenuRenderer.performAction(_:)))
            XCTAssertTrue(item.target === renderer)
            XCTAssertTrue(NSApplication.shared.sendAction(
                try XCTUnwrap(item.action),
                to: item.target,
                from: item
            ))
        }
        XCTAssertEqual(received, [
            .select(target),
            .setSound(false),
            .selectTerminal("com.github.wez.wezterm"),
            .retryUnavailable
        ])
    }

    func testNativeIconApplicationPreservesExactAttentionCountAndAccessibility() throws {
        let button = NSButton()
        let snapshot = presentation(12, node: .heading("TWELVE"))

        NativeStatusItemIconRenderer.apply(
            snapshot.icon,
            accessibilityValue: snapshot.accessibilityValue,
            to: button
        )

        XCTAssertEqual(button.title, "12")
        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertEqual(button.imagePosition, .imageLeading)
        XCTAssertTrue(try XCTUnwrap(button.image).isTemplate)
        XCTAssertEqual(button.accessibilityLabel(), "Herdr")
        XCTAssertEqual(button.accessibilityValue() as? String, "snapshot 12")
    }

    func testNativeIconContentMapsEveryStatusLightStyleAndCount() {
        let disconnected = MenuBarIconPresentation(
            connectionState: .connecting,
            attentionCount: 9
        )
        let clear = MenuBarIconPresentation(connectionState: .connected, attentionCount: 0)
        let attention = MenuBarIconPresentation(
            connectionState: .connected,
            attentionCount: 23
        )

        XCTAssertEqual(
            NativeStatusItemIconRenderer.content(for: disconnected),
            NativeStatusItemIconContent(lightStyle: .hollow, opacity: 0.55, title: "")
        )
        XCTAssertEqual(
            NativeStatusItemIconRenderer.content(for: clear),
            NativeStatusItemIconContent(lightStyle: .solid, opacity: 1, title: "")
        )
        XCTAssertEqual(
            NativeStatusItemIconRenderer.content(for: attention),
            NativeStatusItemIconContent(
                lightStyle: .emphasizedSolid,
                opacity: 1,
                title: "23"
            )
        )
    }
}

@MainActor
private func presentation(_ count: Int, node: StatusMenuNode) -> StatusItemPresentation {
    StatusItemPresentation(
        icon: MenuBarIconPresentation(connectionState: .connected, attentionCount: count),
        accessibilityValue: "snapshot \(count)",
        menu: [node]
    )
}

@MainActor
private func action(in item: NSMenuItem) -> StatusMenuAction? {
    (item.representedObject as? StatusMenuActionToken)?.action
}

@MainActor
private func actionableItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
        var result = item.representedObject is StatusMenuActionToken ? [item] : []
        if let submenu = item.submenu {
            result.append(contentsOf: actionableItems(in: submenu))
        }
        return result
    }
}

@MainActor
private func assertDisabledTextItem(
    _ item: NSMenuItem,
    title: String,
    color: NSColor,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(item.title, title, file: file, line: line)
    XCTAssertFalse(item.isEnabled, file: file, line: line)
    XCTAssertNil(item.representedObject, file: file, line: line)
    XCTAssertEqual(
        item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
        color,
        file: file,
        line: line
    )
}

@MainActor
private final class FakeStatusItemDriver: StatusItemDriving {
    weak var delegate: (any StatusItemDriverDelegate)?
    private(set) var installCount = 0
    private(set) var iconApplications: [IconApplication] = []
    private(set) var menuReplacements: [[StatusMenuNode]] = []
    private(set) var performClickCount = 0
    private(set) var cancelTrackingCount = 0
    private(set) var removeCount = 0
    private var latestAction: ((StatusMenuAction) -> Void)?

    func install(delegate: any StatusItemDriverDelegate) {
        installCount += 1
        self.delegate = delegate
    }

    func applyIcon(
        _ presentation: MenuBarIconPresentation,
        accessibilityValue: String
    ) {
        iconApplications.append(IconApplication(
            presentation: presentation,
            accessibilityValue: accessibilityValue
        ))
    }

    func replaceMenu(
        with nodes: [StatusMenuNode],
        action: @escaping (StatusMenuAction) -> Void
    ) {
        menuReplacements.append(nodes)
        latestAction = action
    }

    func performClick() { performClickCount += 1 }
    func cancelTracking() { cancelTrackingCount += 1 }
    func remove() { removeCount += 1 }

    func simulateMenuWillOpen() { delegate?.statusItemMenuWillOpen() }
    func simulateMenuDidClose() { delegate?.statusItemMenuDidClose() }
    func invokeLatestAction(_ action: StatusMenuAction) { latestAction?(action) }
}

private struct IconApplication: Equatable {
    let presentation: MenuBarIconPresentation
    let accessibilityValue: String
}
