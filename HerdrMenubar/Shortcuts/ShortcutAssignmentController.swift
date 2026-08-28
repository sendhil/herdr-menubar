import Observation

@Observable @MainActor
final class ShortcutAssignmentController {
    private static let unavailableMessage = "That shortcut is unavailable."

    private let registrar: any ShortcutRegistering
    private var values: [ShortcutAction: ShortcutBinding] = [:]
    private var lastKnownGood: [ShortcutAction: ShortcutBinding] = [:]
    private var errorMessages: [ShortcutAction: String] = [:]

    init(registrar: any ShortcutRegistering) {
        self.registrar = registrar
        for action in ShortcutAction.allCases {
            guard let shortcut = registrar.shortcut(for: action) else { continue }
            values[action] = shortcut
            if registrar.isEnabled(for: action) {
                lastKnownGood[action] = shortcut
            } else {
                errorMessages[action] = Self.unavailableMessage
            }
        }
    }

    func shortcut(for action: ShortcutAction) -> ShortcutBinding? {
        values[action]
    }

    func error(for action: ShortcutAction) -> String? {
        errorMessages[action]
    }

    func displayString(for action: ShortcutAction) -> String? {
        guard let shortcut = values[action] else { return nil }
        return registrar.displayString(for: shortcut)
    }

    func assign(_ candidate: ShortcutBinding?, to action: ShortcutAction) {
        errorMessages[action] = nil
        guard let candidate else {
            registrar.setShortcut(nil, for: action)
            values[action] = nil
            lastKnownGood[action] = nil
            return
        }
        guard validate(candidate, for: action) else { return }

        let previous = lastKnownGood[action] ?? values[action]
        registrar.setShortcut(candidate, for: action)
        guard registrar.isEnabled(for: action) else {
            registrar.setShortcut(previous, for: action)
            values[action] = previous
            errorMessages[action] = Self.unavailableMessage
            return
        }

        values[action] = candidate
        lastKnownGood[action] = candidate
    }

    func refreshRegistrationStatus() {
        for action in ShortcutAction.allCases {
            guard let shortcut = values[action] else { continue }
            registrar.retryRegistration(for: action)
            if registrar.isEnabled(for: action) {
                lastKnownGood[action] = shortcut
                errorMessages[action] = nil
            } else {
                errorMessages[action] = Self.unavailableMessage
            }
        }
    }

    func setRecordingActive(_ isActive: Bool) {
        registrar.setGlobalShortcutDeliveryEnabled(!isActive)
    }

    func rejectBareKey(for action: ShortcutAction) {
        errorMessages[action] = "Use Command, Control, or Option with ordinary keys."
    }

    private func validate(_ candidate: ShortcutBinding, for action: ShortcutAction) -> Bool {
        if ShortcutAction.allCases.contains(where: {
            $0 != action && values[$0] == candidate
        }) {
            errorMessages[action] = "That shortcut is already assigned to another Herdr action."
            return false
        }
        if registrar.isTakenBySystem(candidate) {
            errorMessages[action] = "That shortcut is used by macOS."
            return false
        }
        if registrar.conflictsWithMainMenu(candidate) {
            errorMessages[action] = "That shortcut conflicts with an application menu item."
            return false
        }
        return true
    }
}
