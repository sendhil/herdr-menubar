import XCTest
@testable import HerdrMenubar

@MainActor
final class ShortcutAssignmentControllerTests: XCTestCase {
    private let menuShortcut = ShortcutBinding(carbonKeyCode: 0, carbonModifiers: 256)
    private let focusShortcut = ShortcutBinding(carbonKeyCode: 1, carbonModifiers: 2_304)
    private let replacementShortcut = ShortcutBinding(carbonKeyCode: 2, carbonModifiers: 4_096)

    func testBothActionsAreInitiallyUnassigned() {
        let controller = ShortcutAssignmentController(registrar: FakeShortcutRegistrar())

        XCTAssertNil(controller.shortcut(for: .toggleMenu))
        XCTAssertNil(controller.shortcut(for: .focusLatestNotification))
        XCTAssertNil(controller.error(for: .toggleMenu))
        XCTAssertNil(controller.error(for: .focusLatestNotification))
    }

    func testAssignmentsAndClearsAreIndependent() {
        let registrar = FakeShortcutRegistrar()
        registrar.enabledBindings = [menuShortcut, focusShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(menuShortcut, to: .toggleMenu)
        controller.assign(focusShortcut, to: .focusLatestNotification)
        controller.assign(nil, to: .toggleMenu)

        XCTAssertNil(controller.shortcut(for: .toggleMenu))
        XCTAssertEqual(controller.shortcut(for: .focusLatestNotification), focusShortcut)
        XCTAssertNil(registrar.values[.toggleMenu])
        XCTAssertEqual(registrar.values[.focusLatestNotification], focusShortcut)
    }

    func testDuplicateAssignmentIsRejectedWithoutReplacingEitherAction() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.focusLatestNotification] = focusShortcut
        registrar.enabledBindings = [focusShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(focusShortcut, to: .toggleMenu)

        XCTAssertNil(controller.shortcut(for: .toggleMenu))
        XCTAssertEqual(controller.shortcut(for: .focusLatestNotification), focusShortcut)
        XCTAssertEqual(
            controller.error(for: .toggleMenu),
            "That shortcut is already assigned to another Herdr action."
        )
        XCTAssertNil(controller.error(for: .focusLatestNotification))
        XCTAssertEqual(registrar.setCalls, [])
    }

    func testSystemConflictIsRejectedWithoutReplacingPriorAssignment() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut
        registrar.enabledBindings = [menuShortcut]
        registrar.systemShortcuts = [replacementShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(replacementShortcut, to: .toggleMenu)

        XCTAssertEqual(controller.shortcut(for: .toggleMenu), menuShortcut)
        XCTAssertEqual(controller.error(for: .toggleMenu), "That shortcut is used by macOS.")
        XCTAssertEqual(registrar.setCalls, [])
    }

    func testMainMenuConflictIsRejectedWithoutReplacingPriorAssignment() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut
        registrar.enabledBindings = [menuShortcut]
        registrar.mainMenuShortcuts = [replacementShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(replacementShortcut, to: .toggleMenu)

        XCTAssertEqual(controller.shortcut(for: .toggleMenu), menuShortcut)
        XCTAssertEqual(
            controller.error(for: .toggleMenu),
            "That shortcut conflicts with an application menu item."
        )
        XCTAssertEqual(registrar.setCalls, [])
    }

    func testSuccessfulReplacementPersistsAndBecomesKnownGood() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut
        registrar.enabledBindings = [menuShortcut, replacementShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(replacementShortcut, to: .toggleMenu)

        XCTAssertEqual(controller.shortcut(for: .toggleMenu), replacementShortcut)
        XCTAssertEqual(registrar.values[.toggleMenu], replacementShortcut)
        XCTAssertNil(controller.error(for: .toggleMenu))
        XCTAssertEqual(registrar.setCalls, [(.toggleMenu, replacementShortcut)])
    }

    func testUnavailableReplacementRollsBackToPriorKnownGoodValue() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut
        registrar.enabledBindings = [menuShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(replacementShortcut, to: .toggleMenu)

        XCTAssertEqual(registrar.values[.toggleMenu], menuShortcut)
        XCTAssertEqual(controller.shortcut(for: .toggleMenu), menuShortcut)
        XCTAssertEqual(controller.error(for: .toggleMenu), "That shortcut is unavailable.")
        XCTAssertEqual(
            registrar.setCalls,
            [(.toggleMenu, replacementShortcut), (.toggleMenu, menuShortcut)]
        )
    }

    func testUnavailableFirstAssignmentRollsBackToNil() {
        let registrar = FakeShortcutRegistrar()
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(menuShortcut, to: .toggleMenu)

        XCTAssertNil(registrar.values[.toggleMenu])
        XCTAssertNil(controller.shortcut(for: .toggleMenu))
        XCTAssertEqual(controller.error(for: .toggleMenu), "That shortcut is unavailable.")
        XCTAssertEqual(registrar.setCalls, [(.toggleMenu, menuShortcut), (.toggleMenu, nil)])
    }

    func testPersistedUnavailableAssignmentRemainsVisibleAtStartup() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut

        let controller = ShortcutAssignmentController(registrar: registrar)

        XCTAssertEqual(controller.shortcut(for: .toggleMenu), menuShortcut)
        XCTAssertEqual(registrar.values[.toggleMenu], menuShortcut)
        XCTAssertEqual(controller.error(for: .toggleMenu), "That shortcut is unavailable.")
        XCTAssertEqual(registrar.setCalls, [])
    }

    func testActivationRefreshRetriesAndMarksPersistedAssignmentActive() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut
        registrar.bindingsEnabledByRetry[.toggleMenu] = menuShortcut
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.refreshRegistrationStatus()

        XCTAssertEqual(registrar.retryCalls, [.toggleMenu])
        XCTAssertEqual(controller.shortcut(for: .toggleMenu), menuShortcut)
        XCTAssertNil(controller.error(for: .toggleMenu))
    }

    func testRefreshRetriesEachPersistedAssignmentOnceAndKeepsFailuresVisible() {
        let registrar = FakeShortcutRegistrar()
        registrar.values[.toggleMenu] = menuShortcut
        registrar.values[.focusLatestNotification] = focusShortcut
        registrar.bindingsEnabledByRetry[.toggleMenu] = menuShortcut
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.refreshRegistrationStatus()

        XCTAssertEqual(registrar.retryCalls, [.toggleMenu, .focusLatestNotification])
        XCTAssertNil(controller.error(for: .toggleMenu))
        XCTAssertEqual(
            controller.error(for: .focusLatestNotification),
            "That shortcut is unavailable."
        )
        XCTAssertEqual(controller.shortcut(for: .focusLatestNotification), focusShortcut)
    }

    func testErrorsAreScopedToTheirAction() {
        let registrar = FakeShortcutRegistrar()
        registrar.enabledBindings = [focusShortcut]
        registrar.systemShortcuts = [menuShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(menuShortcut, to: .toggleMenu)
        controller.assign(focusShortcut, to: .focusLatestNotification)

        XCTAssertEqual(controller.error(for: .toggleMenu), "That shortcut is used by macOS.")
        XCTAssertNil(controller.error(for: .focusLatestNotification))
        XCTAssertEqual(controller.shortcut(for: .focusLatestNotification), focusShortcut)
    }

    func testAssignmentDoesNotRequestDisplayTextOrPersistOutsideRegistrar() {
        let registrar = FakeShortcutRegistrar()
        registrar.enabledBindings = [menuShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(menuShortcut, to: .toggleMenu)

        XCTAssertEqual(registrar.displayStringCalls, [])
        XCTAssertEqual(registrar.setCalls, [(.toggleMenu, menuShortcut)])
    }
}

@MainActor
private final class FakeShortcutRegistrar: ShortcutRegistering {
    var values: [ShortcutAction: ShortcutBinding] = [:]
    var enabledBindings: Set<ShortcutBinding> = []
    var systemShortcuts: Set<ShortcutBinding> = []
    var mainMenuShortcuts: Set<ShortcutBinding> = []
    var bindingsEnabledByRetry: [ShortcutAction: ShortcutBinding] = [:]
    private(set) var setCalls: [(ShortcutAction, ShortcutBinding?)] = []
    private(set) var retryCalls: [ShortcutAction] = []
    private(set) var displayStringCalls: [ShortcutBinding] = []

    func shortcut(for action: ShortcutAction) -> ShortcutBinding? {
        values[action]
    }

    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction) {
        values[action] = shortcut
        setCalls.append((action, shortcut))
    }

    func isEnabled(for action: ShortcutAction) -> Bool {
        guard let shortcut = values[action] else { return false }
        return enabledBindings.contains(shortcut)
    }

    func retryRegistration(for action: ShortcutAction) {
        retryCalls.append(action)
        if let binding = bindingsEnabledByRetry[action] {
            enabledBindings.insert(binding)
        }
    }

    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool {
        systemShortcuts.contains(shortcut)
    }

    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool {
        mainMenuShortcuts.contains(shortcut)
    }

    func displayString(for shortcut: ShortcutBinding) -> String {
        displayStringCalls.append(shortcut)
        return "redacted"
    }

    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent> {
        AsyncStream { $0.finish() }
    }
}

private func XCTAssertEqual(
    _ lhs: [(ShortcutAction, ShortcutBinding?)],
    _ rhs: [(ShortcutAction, ShortcutBinding?)],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (actual, expected) in zip(lhs, rhs) {
        XCTAssertEqual(actual.0, expected.0, file: file, line: line)
        XCTAssertEqual(actual.1, expected.1, file: file, line: line)
    }
}
