import AppKit
import SwiftUI

@MainActor
protocol KeyboardShortcutSettingsWindowDriving: AnyObject {
    func makeWindow(rootView: AnyView) -> NSWindow
    func activateApplication()
    func makeKeyAndOrderFront(_ window: NSWindow)
    func close(_ window: NSWindow)
}

@MainActor
final class KeyboardShortcutSettingsWindowController {
    private let assignmentController: ShortcutAssignmentController
    private let driver: any KeyboardShortcutSettingsWindowDriving
    private var window: NSWindow?
    private var isStopped = false

    init(
        assignmentController: ShortcutAssignmentController,
        driver: any KeyboardShortcutSettingsWindowDriving =
            LiveKeyboardShortcutSettingsWindowDriver()
    ) {
        self.assignmentController = assignmentController
        self.driver = driver
    }

    func show() {
        guard !isStopped else { return }
        let window = window ?? makeWindow()
        driver.activateApplication()
        driver.makeKeyAndOrderFront(window)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        guard let window else { return }
        driver.close(window)
    }

    private func makeWindow() -> NSWindow {
        let window = driver.makeWindow(
            rootView: AnyView(KeyboardShortcutSettingsView(controller: assignmentController))
        )
        self.window = window
        return window
    }
}

@MainActor
final class LiveKeyboardShortcutSettingsWindowDriver:
    KeyboardShortcutSettingsWindowDriving
{
    func makeWindow(rootView: AnyView) -> NSWindow {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        hostingController.view.layoutSubtreeIfNeeded()
        window.setContentSize(hostingController.view.fittingSize)
        window.center()
        return window
    }

    func activateApplication() {
        NSApp.activate()
    }

    func makeKeyAndOrderFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ window: NSWindow) {
        window.close()
    }
}
