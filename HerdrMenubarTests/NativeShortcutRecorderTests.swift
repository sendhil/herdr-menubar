import AppKit
import SwiftUI
import XCTest
@testable import HerdrMenubar

@MainActor
final class NativeShortcutRecorderTests: XCTestCase {
    func testControlIsAFirstResponderButtonWithoutTextOrMonitorStorage() {
        let control = NativeShortcutRecorderControl()

        XCTAssertTrue(control.acceptsFirstResponder)
        XCTAssertEqual(control.bezelStyle, .rounded)
        XCTAssertFalse((control as NSView) is NSTextField)
        XCTAssertFalse(
            Mirror(reflecting: control).children
                .compactMap(\.label)
                .contains { $0.localizedCaseInsensitiveContains("monitor") }
        )
    }

    func testMouseDownMakesControlFirstResponder() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentLayoutRect)
        let control = NativeShortcutRecorderControl(
            frame: NSRect(x: 20, y: 20, width: 200, height: 32)
        )
        contentView.addSubview(control)
        window.contentView = contentView
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(window.firstResponder === control)

        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: control.frame.midX, y: control.frame.midY),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let mouseUp = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: mouseDown.locationInWindow,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            )
        )
        NSApp.postEvent(mouseUp, atStart: true)

        control.mouseDown(with: mouseDown)

        XCTAssertTrue(window.firstResponder === control)
    }

    func testOrdinaryKeyCapturesWithCommandControlOrOption() {
        let allowedModifiers: [NSEvent.ModifierFlags] = [.command, .control, .option]

        for modifiers in allowedModifiers {
            let control = NativeShortcutRecorderControl()
            var captured: ShortcutBinding?
            control.onCapture = { captured = $0 }

            control.keyDown(with: keyEvent(keyCode: 0, modifiers: modifiers))

            XCTAssertEqual(captured?.carbonKeyCode, 0)
            XCTAssertEqual(captured?.modifiers, modifiers)
        }
    }

    func testUnmodifiedFunctionKeyCaptures() {
        let control = NativeShortcutRecorderControl()
        var captured: ShortcutBinding?
        control.onCapture = { captured = $0 }

        control.keyDown(with: keyEvent(keyCode: 122))

        XCTAssertEqual(captured?.carbonKeyCode, 122)
        XCTAssertEqual(captured?.modifiers, [])
    }

    func testEscapeCancelsWithoutMutatingAssignment() {
        let control = NativeShortcutRecorderControl()
        var cancelCount = 0
        var captureCount = 0
        var clearCount = 0
        control.onCancel = { cancelCount += 1 }
        control.onCapture = { _ in captureCount += 1 }
        control.onClear = { clearCount += 1 }

        control.keyDown(with: keyEvent(keyCode: 53))

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(captureCount, 0)
        XCTAssertEqual(clearCount, 0)
    }

    func testEscapeEndsRecordingByResigningFirstResponder() {
        let control = NativeShortcutRecorderControl()
        let window = recorderWindow(control: control)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(control))

        control.keyDown(with: keyEvent(keyCode: 53))

        XCTAssertFalse(window.firstResponder === control)
    }

    func testSuccessfulCaptureResignsFirstResponder() {
        let control = NativeShortcutRecorderControl()
        let window = recorderWindow(control: control)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(control))

        control.keyDown(with: keyEvent(keyCode: 0, modifiers: .command))

        XCTAssertFalse(window.firstResponder === control)
    }

    func testTabEndsRecordingAndAdvancesKeyViewNavigation() {
        let previous = FocusableTestView()
        let control = NativeShortcutRecorderControl()
        let next = FocusableTestView()
        let window = recorderWindow(control: control, siblings: [previous, next])
        defer { window.close() }
        previous.nextKeyView = control
        control.nextKeyView = next
        next.nextKeyView = previous
        XCTAssertTrue(window.makeFirstResponder(control))

        control.keyDown(with: keyEvent(keyCode: 48))

        XCTAssertTrue(window.firstResponder === next)
    }

    func testShiftTabEndsRecordingAndRetreatsKeyViewNavigation() {
        let previous = FocusableTestView()
        let control = NativeShortcutRecorderControl()
        let next = FocusableTestView()
        let window = recorderWindow(control: control, siblings: [previous, next])
        defer { window.close() }
        previous.nextKeyView = control
        control.nextKeyView = next
        next.nextKeyView = previous
        XCTAssertTrue(window.makeFirstResponder(control))

        control.keyDown(with: keyEvent(keyCode: 48, modifiers: .shift))

        XCTAssertTrue(window.firstResponder === previous)
    }

    func testAutoRepeatIsIgnored() {
        let control = NativeShortcutRecorderControl()
        var callbackCount = 0
        control.onCapture = { _ in callbackCount += 1 }
        control.onCancel = { callbackCount += 1 }
        control.onClear = { callbackCount += 1 }
        control.onInvalidBareKey = { callbackCount += 1 }

        control.keyDown(
            with: keyEvent(keyCode: 0, modifiers: .command, isARepeat: true)
        )

        XCTAssertEqual(callbackCount, 0)
    }

    func testFirstResponderLifecyclePausesAndResumesExactlyOnce() {
        let control = NativeShortcutRecorderControl()
        var recordingStates: [Bool] = []
        control.onRecordingChange = { recordingStates.append($0) }
        let window = recorderWindow(control: control)
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(control))
        XCTAssertEqual(recordingStates, [true])
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(recordingStates, [true, false])

        _ = control.resignFirstResponder()
        XCTAssertEqual(recordingStates, [true, false])
    }

    func testRemovingActiveRecorderResumesExactlyOnce() {
        let control = NativeShortcutRecorderControl()
        var recordingStates: [Bool] = []
        control.onRecordingChange = { recordingStates.append($0) }
        let window = recorderWindow(control: control)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(control))

        control.removeFromSuperview()

        XCTAssertEqual(recordingStates, [true, false])
    }

    func testClosingWindowWithActiveRecorderResumesExactlyOnce() {
        let control = NativeShortcutRecorderControl()
        var recordingStates: [Bool] = []
        control.onRecordingChange = { recordingStates.append($0) }
        let window = recorderWindow(control: control)
        XCTAssertTrue(window.makeFirstResponder(control))

        window.close()

        XCTAssertEqual(recordingStates, [true, false])
    }

    func testSuccessfulCaptureResumesDeliveryBeforeCaptureCallback() {
        let control = NativeShortcutRecorderControl()
        var deliveryIsEnabled = true
        var events: [String] = []
        control.onRecordingChange = { isRecording in
            deliveryIsEnabled = !isRecording
            events.append(isRecording ? "pause" : "resume")
        }
        control.onCapture = { _ in
            events.append(deliveryIsEnabled ? "capture-enabled" : "capture-disabled")
        }
        let window = recorderWindow(control: control)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(control))

        control.keyDown(with: keyEvent(keyCode: 0, modifiers: .command))

        XCTAssertEqual(events, ["pause", "resume", "capture-enabled"])
    }

    func testDeleteInvokesClearExactlyOnce() {
        let control = NativeShortcutRecorderControl()
        var clearCount = 0
        control.onClear = { clearCount += 1 }

        control.keyDown(with: keyEvent(keyCode: 51))

        XCTAssertEqual(clearCount, 1)
    }

    func testForwardDeleteInvokesClearExactlyOnce() {
        let control = NativeShortcutRecorderControl()
        var clearCount = 0
        control.onClear = { clearCount += 1 }

        control.keyDown(with: keyEvent(keyCode: 117))

        XCTAssertEqual(clearCount, 1)
    }

    func testBareOrdinaryKeyIsRejected() {
        let control = NativeShortcutRecorderControl()
        var invalidCount = 0
        var captured: ShortcutBinding?
        control.onInvalidBareKey = { invalidCount += 1 }
        control.onCapture = { captured = $0 }

        control.keyDown(with: keyEvent(keyCode: 0))

        XCTAssertEqual(invalidCount, 1)
        XCTAssertNil(captured)
    }

    func testShiftOnlyOrdinaryKeyIsRejected() {
        let control = NativeShortcutRecorderControl()
        var invalidCount = 0
        var captured: ShortcutBinding?
        control.onInvalidBareKey = { invalidCount += 1 }
        control.onCapture = { captured = $0 }

        control.keyDown(with: keyEvent(keyCode: 0, modifiers: .shift))

        XCTAssertEqual(invalidCount, 1)
        XCTAssertNil(captured)
    }

    func testRepresentableRefreshesTitleAndAccessibilityFromDisplayString() throws {
        let host = NSHostingView(
            rootView: recorder(displayString: "Unassigned", accessibilityLabel: "Toggle Herdr Menu")
        )
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(findRecorder(in: host))
        XCTAssertEqual(control.title, "Unassigned")
        XCTAssertEqual(control.accessibilityLabel(), "Toggle Herdr Menu")
        XCTAssertEqual(control.accessibilityValue() as? String, "Unassigned")

        host.rootView = recorder(displayString: "⌘A", accessibilityLabel: "Toggle Herdr Menu")
        host.layoutSubtreeIfNeeded()

        let updatedControl = try XCTUnwrap(findRecorder(in: host))
        XCTAssertTrue(updatedControl === control)
        XCTAssertEqual(updatedControl.title, "⌘A")
        XCTAssertEqual(updatedControl.accessibilityLabel(), "Toggle Herdr Menu")
        XCTAssertEqual(updatedControl.accessibilityValue() as? String, "⌘A")
    }

    func testRepresentableReplacesEventClosuresWhenModelUpdates() throws {
        var oldCaptureCount = 0
        var newCaptureCount = 0
        let initial = recorder(displayString: "Unassigned") { _ in oldCaptureCount += 1 }
        let host = NSHostingView(rootView: initial)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(findRecorder(in: host))

        host.rootView = recorder(displayString: "Unassigned") { _ in newCaptureCount += 1 }
        host.layoutSubtreeIfNeeded()
        control.keyDown(with: keyEvent(keyCode: 0, modifiers: .command))

        XCTAssertEqual(oldCaptureCount, 0)
        XCTAssertEqual(newCaptureCount, 1)
    }

    private func recorder(
        displayString: String,
        accessibilityLabel: String = "Shortcut",
        onCapture: @escaping (ShortcutBinding) -> Void = { _ in }
    ) -> NativeShortcutRecorder {
        NativeShortcutRecorder(
            displayString: displayString,
            accessibilityLabel: accessibilityLabel,
            onCapture: onCapture,
            onCancel: {},
            onClear: {},
            onInvalidBareKey: {},
            onRecordingChange: { _ in }
        )
    }

    private func findRecorder(in view: NSView) -> NativeShortcutRecorderControl? {
        if let recorder = view as? NativeShortcutRecorderControl {
            return recorder
        }
        for subview in view.subviews {
            if let recorder = findRecorder(in: subview) {
                return recorder
            }
        }
        return nil
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }

    private func recorderWindow(
        control: NativeShortcutRecorderControl,
        siblings: [NSView] = []
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: window.contentLayoutRect)
        ([control] + siblings).enumerated().forEach { index, view in
            view.frame = NSRect(x: 20 + (index * 95), y: 30, width: 90, height: 32)
            contentView.addSubview(view)
        }
        window.contentView = contentView
        window.orderFront(nil)
        return window
    }
}

@MainActor
private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}
