import AppKit
import KeyboardShortcuts

enum ShortcutAction: String, CaseIterable, Hashable, Sendable {
    case toggleMenu
    case focusLatestNotification
}

struct ShortcutBinding: Equatable, Hashable, Sendable {
    let carbonKeyCode: Int
    let carbonModifiers: Int

    var modifiers: NSEvent.ModifierFlags {
        packageShortcut.modifiers
    }

    fileprivate var packageShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: carbonKeyCode,
            carbonModifiers: carbonModifiers
        )
    }
}

enum GlobalShortcutEvent: Equatable, Sendable {
    case keyDown
    case keyUp
}

@MainActor
protocol ShortcutRegistering: AnyObject {
    func shortcut(for action: ShortcutAction) -> ShortcutBinding?
    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction)
    func isEnabled(for action: ShortcutAction) -> Bool
    func retryRegistration(for action: ShortcutAction)
    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool
    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool
    func displayString(for shortcut: ShortcutBinding) -> String
    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent>
    func setGlobalShortcutDeliveryEnabled(_ isEnabled: Bool)
}

extension KeyboardShortcuts.Name {
    static let toggleHerdrMenu = Self("toggleHerdrMenu")
    static let focusLatestHerdrNotification = Self("focusLatestHerdrNotification")
}

@MainActor
final class LiveShortcutRegistrar: ShortcutRegistering {
    func shortcut(for action: ShortcutAction) -> ShortcutBinding? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name(for: action)) else {
            return nil
        }
        return ShortcutBinding(
            carbonKeyCode: shortcut.carbonKeyCode,
            carbonModifiers: shortcut.carbonModifiers
        )
    }

    func setShortcut(_ shortcut: ShortcutBinding?, for action: ShortcutAction) {
        KeyboardShortcuts.setShortcut(shortcut?.packageShortcut, for: name(for: action))
    }

    func isEnabled(for action: ShortcutAction) -> Bool {
        KeyboardShortcuts.isEnabled(for: name(for: action))
    }

    func retryRegistration(for action: ShortcutAction) {
        KeyboardShortcuts.enable(name(for: action))
    }

    func isTakenBySystem(_ shortcut: ShortcutBinding) -> Bool {
        shortcut.packageShortcut.isTakenBySystem
    }

    func conflictsWithMainMenu(_ shortcut: ShortcutBinding) -> Bool {
        guard
            let keyEquivalent = shortcut.packageShortcut.nsMenuItemKeyEquivalent,
            let mainMenu = NSApp.mainMenu
        else {
            return false
        }

        return containsShortcut(
            keyEquivalent: keyEquivalent,
            modifiers: shortcut.modifiers,
            in: mainMenu
        )
    }

    func displayString(for shortcut: ShortcutBinding) -> String {
        shortcut.packageShortcut.description
    }

    func events(for action: ShortcutAction) -> AsyncStream<GlobalShortcutEvent> {
        let packageEvents = KeyboardShortcuts.events(for: name(for: action))
        return AsyncStream { continuation in
            let producer = Task { @MainActor in
                for await event in packageEvents {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .keyDown:
                        continuation.yield(.keyDown)
                    case .keyUp:
                        continuation.yield(.keyUp)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    func setGlobalShortcutDeliveryEnabled(_ isEnabled: Bool) {
        KeyboardShortcuts.isEnabled = isEnabled
    }

    private func name(for action: ShortcutAction) -> KeyboardShortcuts.Name {
        switch action {
        case .toggleMenu:
            .toggleHerdrMenu
        case .focusLatestNotification:
            .focusLatestHerdrNotification
        }
    }

    private func containsShortcut(
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        in menu: NSMenu
    ) -> Bool {
        for item in menu.items {
            var itemKeyEquivalent = item.keyEquivalent
            var itemModifiers = item.keyEquivalentModifierMask
            if modifiers.contains(.shift),
               itemKeyEquivalent.lowercased() != itemKeyEquivalent {
                itemKeyEquivalent = itemKeyEquivalent.lowercased()
                itemModifiers.insert(.shift)
            }

            if keyEquivalent == itemKeyEquivalent, modifiers == itemModifiers {
                return true
            }
            if let submenu = item.submenu,
               containsShortcut(
                   keyEquivalent: keyEquivalent,
                   modifiers: modifiers,
                   in: submenu
               ) {
                return true
            }
        }
        return false
    }
}
