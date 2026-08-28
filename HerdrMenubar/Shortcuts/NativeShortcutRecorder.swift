import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class NativeShortcutRecorderControl: NSButton {
    var onCapture: ((ShortcutBinding) -> Void)?
    var onCancel: (() -> Void)?
    var onClear: (() -> Void)?
    var onInvalidBareKey: (() -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 51, 117:
            onClear?()
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
}

struct NativeShortcutRecorder: NSViewRepresentable {
    let displayString: String
    let accessibilityLabel: String
    let onCapture: (ShortcutBinding) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    let onInvalidBareKey: () -> Void

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
    }
}
