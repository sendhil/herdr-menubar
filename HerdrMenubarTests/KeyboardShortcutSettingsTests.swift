import AppKit
import SwiftUI
import XCTest
@testable import HerdrMenubar

@MainActor
final class KeyboardShortcutSettingsTests: XCTestCase {
    private let menuShortcut = ShortcutBinding(carbonKeyCode: 0, carbonModifiers: 256)
    private let focusShortcut = ShortcutBinding(carbonKeyCode: 1, carbonModifiers: 2_304)

    func testPresentationHasTwoExactInitiallyUnassignedRowsAndCurrentRunExplanation() {
        let controller = ShortcutAssignmentController(registrar: SettingsShortcutRegistrar())

        let presentation = KeyboardShortcutSettingsPresentation(controller: controller)

        XCTAssertEqual(presentation.rows.map(\.title), [
            "Toggle Herdr Menu",
            "Focus Latest Notification",
        ])
        XCTAssertEqual(presentation.rows.map(\.displayString), ["Unassigned", "Unassigned"])
        XCTAssertEqual(presentation.rows.map(\.isClearEnabled), [false, false])
        XCTAssertEqual(presentation.rows.map(\.errorMessage), [nil, nil])
        XCTAssertEqual(
            presentation.explanation,
            "The latest notification shortcut uses notifications delivered during this app run."
        )
    }

    func testPresentationUsesIndependentAssignmentsDisplayStringsAndClearEnablement() {
        let registrar = SettingsShortcutRegistrar()
        registrar.enabledBindings = [menuShortcut, focusShortcut]
        registrar.displayStrings[menuShortcut] = "Command-A"
        registrar.displayStrings[focusShortcut] = "Control-B"
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(menuShortcut, to: .toggleMenu)
        controller.assign(focusShortcut, to: .focusLatestNotification)
        var presentation = KeyboardShortcutSettingsPresentation(controller: controller)

        XCTAssertEqual(presentation.rows.map(\.displayString), ["Command-A", "Control-B"])
        XCTAssertEqual(presentation.rows.map(\.isClearEnabled), [true, true])

        controller.assign(nil, to: .toggleMenu)
        presentation = KeyboardShortcutSettingsPresentation(controller: controller)

        XCTAssertEqual(presentation.rows.map(\.displayString), ["Unassigned", "Control-B"])
        XCTAssertEqual(presentation.rows.map(\.isClearEnabled), [false, true])
        XCTAssertNil(controller.shortcut(for: .toggleMenu))
        XCTAssertEqual(controller.shortcut(for: .focusLatestNotification), focusShortcut)
    }

    func testPresentationKeepsInlineErrorsScopedToExactAction() {
        let registrar = SettingsShortcutRegistrar()
        registrar.systemShortcuts = [menuShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)

        controller.assign(menuShortcut, to: .toggleMenu)
        controller.assign(focusShortcut, to: .focusLatestNotification)

        let presentation = KeyboardShortcutSettingsPresentation(controller: controller)

        XCTAssertEqual(presentation.rows[0].errorMessage, "That shortcut is used by macOS.")
        XCTAssertEqual(presentation.rows[1].errorMessage, "That shortcut is unavailable.")
    }

    func testRowAccessibilityLabelsAreDistinctPerActionAndControl() {
        let controller = ShortcutAssignmentController(registrar: SettingsShortcutRegistrar())

        let rows = KeyboardShortcutSettingsPresentation(controller: controller).rows

        XCTAssertEqual(Set(rows.map(\.recorderAccessibilityLabel)).count, 2)
        XCTAssertEqual(Set(rows.map(\.clearAccessibilityLabel)).count, 2)
        XCTAssertEqual(
            Set(rows.flatMap { [$0.recorderAccessibilityLabel, $0.clearAccessibilityLabel] })
                .count,
            4
        )
    }

    func testViewRecorderCaptureClearAndRecordingLifecycleRouteThroughAssignmentController() throws {
        _ = NSApplication.shared
        let registrar = SettingsShortcutRegistrar()
        registrar.enabledBindings = [menuShortcut]
        registrar.displayStrings[menuShortcut] = "Command-A"
        let controller = ShortcutAssignmentController(registrar: registrar)
        let hostingController = NSHostingController(
            rootView: KeyboardShortcutSettingsView(controller: controller)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.orderFront(nil)
        defer { window.close() }
        hostingController.view.layoutSubtreeIfNeeded()
        let recorders = recorderControls(in: hostingController.view)
        let menuRecorder = try XCTUnwrap(recorders.first {
            $0.accessibilityLabel() == "Toggle Herdr Menu shortcut recorder"
        })

        menuRecorder.onCapture?(menuShortcut)
        XCTAssertEqual(controller.shortcut(for: .toggleMenu), menuShortcut)

        XCTAssertTrue(window.makeFirstResponder(menuRecorder))
        XCTAssertEqual(registrar.globalDeliveryEnabledCalls, [false])
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(registrar.globalDeliveryEnabledCalls, [false, true])

        menuRecorder.onClear?()
        XCTAssertNil(controller.shortcut(for: .toggleMenu))
    }

    func testBareKeyRecorderFailureProducesOnlyActionScopedInlineError() throws {
        _ = NSApplication.shared
        let controller = ShortcutAssignmentController(registrar: SettingsShortcutRegistrar())
        let hostingController = NSHostingController(
            rootView: KeyboardShortcutSettingsView(controller: controller)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.orderFront(nil)
        defer { window.close() }
        hostingController.view.layoutSubtreeIfNeeded()
        let focusRecorder = try XCTUnwrap(recorderControls(in: hostingController.view).first {
            $0.accessibilityLabel() == "Focus Latest Notification shortcut recorder"
        })

        focusRecorder.onInvalidBareKey?()

        let presentation = KeyboardShortcutSettingsPresentation(controller: controller)
        XCTAssertNil(presentation.rows[0].errorMessage)
        XCTAssertEqual(
            presentation.rows[1].errorMessage,
            "Use Command, Control, or Option with ordinary keys."
        )
    }

    func testRenderedErrorAccessibilitySpeaksActionAndExactDynamicReason() {
        _ = NSApplication.shared
        let registrar = SettingsShortcutRegistrar()
        registrar.systemShortcuts = [menuShortcut]
        let controller = ShortcutAssignmentController(registrar: registrar)
        controller.assign(menuShortcut, to: .toggleMenu)
        controller.assign(focusShortcut, to: .focusLatestNotification)
        let hostingController = NSHostingController(
            rootView: KeyboardShortcutSettingsView(controller: controller)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.orderFront(nil)
        defer { window.close() }
        hostingController.view.layoutSubtreeIfNeeded()

        let spokenErrors = accessibilityStrings(in: hostingController.view)
            .filter { $0.localizedCaseInsensitiveContains("shortcut error") }

        XCTAssertTrue(spokenErrors.contains(
            "Toggle Herdr Menu shortcut error: That shortcut is used by macOS."
        ), "Accessibility strings: \(spokenErrors)")
        XCTAssertTrue(spokenErrors.contains(
            "Focus Latest Notification shortcut error: That shortcut is unavailable."
        ), "Accessibility strings: \(spokenErrors)")

        controller.rejectBareKey(for: .toggleMenu)
        hostingController.view.layoutSubtreeIfNeeded()
        let updatedSpokenErrors = accessibilityStrings(in: hostingController.view)
            .filter { $0.localizedCaseInsensitiveContains("shortcut error") }

        XCTAssertTrue(updatedSpokenErrors.contains(
            "Toggle Herdr Menu shortcut error: "
                + "Use Command, Control, or Option with ordinary keys."
        ), "Updated accessibility strings: \(updatedSpokenErrors)")
        XCTAssertFalse(updatedSpokenErrors.contains(
            "Toggle Herdr Menu shortcut error: That shortcut is used by macOS."
        ), "Updated accessibility strings: \(updatedSpokenErrors)")
    }

    func testShowTwiceCreatesOneWindowAndOrdersItFrontTwice() {
        let driver = FakeKeyboardShortcutSettingsWindowDriver()
        let controller = KeyboardShortcutSettingsWindowController(
            assignmentController: ShortcutAssignmentController(
                registrar: SettingsShortcutRegistrar()
            ),
            driver: driver
        )

        controller.show()
        controller.show()

        XCTAssertEqual(driver.makeWindowCount, 1)
        XCTAssertEqual(driver.activateCount, 2)
        XCTAssertEqual(driver.makeKeyAndOrderFrontCount, 2)
        XCTAssertTrue(driver.orderedWindows[0] === driver.orderedWindows[1])
    }

    func testStopClosesOnceAndPermanentlyIgnoresShow() {
        let driver = FakeKeyboardShortcutSettingsWindowDriver()
        let controller = KeyboardShortcutSettingsWindowController(
            assignmentController: ShortcutAssignmentController(
                registrar: SettingsShortcutRegistrar()
            ),
            driver: driver
        )
        controller.show()

        controller.stop()
        controller.stop()
        controller.show()

        XCTAssertEqual(driver.closeCount, 1)
        XCTAssertEqual(driver.makeWindowCount, 1)
        XCTAssertEqual(driver.activateCount, 1)
        XCTAssertEqual(driver.makeKeyAndOrderFrontCount, 1)
    }

    func testLiveWindowHasReusableNonresizableStandardConfiguration() {
        _ = NSApplication.shared
        let driver = LiveKeyboardShortcutSettingsWindowDriver()
        let window = driver.makeWindow(rootView: AnyView(Text("Settings")))
        defer { window.close() }

        XCTAssertEqual(window.title, "Keyboard Shortcuts")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertGreaterThan(window.contentLayoutRect.width, 0)
        XCTAssertGreaterThan(window.contentLayoutRect.height, 0)

        window.close()
        driver.makeKeyAndOrderFront(window)

        XCTAssertTrue(window.isVisible)
    }

    private func recorderControls(in view: NSView) -> [NativeShortcutRecorderControl] {
        var result = view.subviews.flatMap(recorderControls(in:))
        if let recorder = view as? NativeShortcutRecorderControl {
            result.insert(recorder, at: 0)
        }
        return result
    }

    private func accessibilityStrings(in view: NSView) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        return accessibilityStrings(in: view, visited: &visited)
    }

    private func accessibilityStrings(
        in object: Any,
        visited: inout Set<ObjectIdentifier>
    ) -> [String] {
        guard let accessible = object as? NSObject else { return [] }
        let identifier = ObjectIdentifier(accessible)
        guard visited.insert(identifier).inserted else { return [] }

        var strings = [
            accessibilityString("accessibilityLabel", from: accessible),
            accessibilityString("accessibilityValue", from: accessible),
        ].compactMap { $0 }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        let accessibilityChildren = accessible.responds(to: childrenSelector)
            ? accessible.value(forKey: "accessibilityChildren") as? [Any] ?? []
            : []
        for child in accessibilityChildren {
            strings.append(contentsOf: accessibilityStrings(in: child, visited: &visited))
        }
        if let view = object as? NSView {
            for subview in view.subviews {
                strings.append(contentsOf: accessibilityStrings(in: subview, visited: &visited))
            }
        }
        return strings
    }

    private func accessibilityString(_ key: String, from object: NSObject) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.value(forKey: key) as? String
    }
}

@MainActor
private final class SettingsShortcutRegistrar: ShortcutRegistering {
    var values: [ShortcutAction: ShortcutBinding] = [:]
    var enabledBindings: Set<ShortcutBinding> = []
    var systemShortcuts: Set<ShortcutBinding> = []
    var displayStrings: [ShortcutBinding: String] = [:]
    private(set) var globalDeliveryEnabledCalls: [Bool] = []

    func shortcut(for action: ShortcutAction) -> ShortcutBinding? { values[action] }

    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction) {
        values[action] = shortcut
    }

    func isEnabled(for action: ShortcutAction) -> Bool {
        values[action].map(enabledBindings.contains) ?? false
    }

    func retryRegistration(for action: ShortcutAction) {}

    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool {
        systemShortcuts.contains(shortcut)
    }

    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool { false }

    func displayString(for shortcut: ShortcutBinding) -> String {
        displayStrings[shortcut] ?? "Unknown"
    }

    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent> {
        AsyncStream { $0.finish() }
    }

    func setGlobalShortcutDeliveryEnabled(_ isEnabled: Bool) {
        globalDeliveryEnabledCalls.append(isEnabled)
    }
}

@MainActor
private final class FakeKeyboardShortcutSettingsWindowDriver:
    KeyboardShortcutSettingsWindowDriving
{
    private(set) var makeWindowCount = 0
    private(set) var activateCount = 0
    private(set) var makeKeyAndOrderFrontCount = 0
    private(set) var closeCount = 0
    private(set) var orderedWindows: [NSWindow] = []

    func makeWindow(rootView: AnyView) -> NSWindow {
        makeWindowCount += 1
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func activateApplication() {
        activateCount += 1
    }

    func makeKeyAndOrderFront(_ window: NSWindow) {
        makeKeyAndOrderFrontCount += 1
        orderedWindows.append(window)
    }

    func close(_ window: NSWindow) {
        closeCount += 1
    }
}
