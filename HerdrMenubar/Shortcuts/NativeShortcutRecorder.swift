import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class NativeShortcutRecorderControl: NSButton {
    var onCapture: ((ShortcutBinding) -> Void)?
    var onCancel: (() -> Void)?
    var onClear: (() -> Void)?
    var onInvalidBareKey: (() -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var isRecording = false
    private weak var observedWindow: NSWindow?

    private static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            beginRecordingIfNeeded()
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            endRecordingIfNeeded()
        }
        return didResignFirstResponder
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let observedWindow, observedWindow !== newWindow {
            removeLifecycleObservers(from: observedWindow)
            self.observedWindow = nil
            if observedWindow.firstResponder === self {
                observedWindow.makeFirstResponder(nil)
            }
            endRecordingIfNeeded()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, observedWindow !== window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }

        switch event.keyCode {
        case 53:
            resignAndEndRecording()
            onCancel?()
        case 51, 117:
            onClear?()
        case 48:
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            resignAndEndRecording()
        default:
            guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
                NSSound.beep()
                return
            }
            let binding = ShortcutBinding(
                carbonKeyCode: shortcut.carbonKeyCode,
                carbonModifiers: shortcut.carbonModifiers
            )
            guard Self.hasRequiredModifierOrIsFunctionKey(binding) else {
                onInvalidBareKey?()
                return
            }
            resignAndEndRecording()
            onCapture?(binding)
        }
    }

    static func hasRequiredModifierOrIsFunctionKey(_ binding: ShortcutBinding) -> Bool {
        let required: NSEvent.ModifierFlags = [.command, .control, .option]
        return !binding.modifiers.intersection(required).isEmpty
            || functionKeyCodes.contains(binding.carbonKeyCode)
    }

    private func configureAppearance() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        focusRingType = .default
        isBordered = true
    }

    private func beginRecordingIfNeeded() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChange?(true)
    }

    private func resignAndEndRecording() {
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
        endRecordingIfNeeded()
    }

    private func endRecordingIfNeeded() {
        guard isRecording else { return }
        isRecording = false
        onRecordingChange?(false)
    }

    private func removeLifecycleObservers(from window: NSWindow) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        resignAndEndRecording()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        resignAndEndRecording()
    }
}

struct NativeShortcutRecorder: NSViewRepresentable {
    let displayString: String
    let accessibilityLabel: String
    let onCapture: (ShortcutBinding) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    let onInvalidBareKey: () -> Void
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> NativeShortcutRecorderControl {
        NativeShortcutRecorderControl()
    }

    func updateNSView(_ control: NativeShortcutRecorderControl, context: Context) {
        control.title = displayString
        control.setAccessibilityLabel(accessibilityLabel)
        control.setAccessibilityValue(displayString)
        control.onCapture = onCapture
        control.onCancel = onCancel
        control.onClear = onClear
        control.onInvalidBareKey = onInvalidBareKey
        control.onRecordingChange = onRecordingChange
    }
}
