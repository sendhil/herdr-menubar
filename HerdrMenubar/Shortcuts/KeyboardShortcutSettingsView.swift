import SwiftUI

struct ShortcutSettingsRowPresentation: Equatable, Identifiable {
    let action: ShortcutAction
    let title: String
    let displayString: String
    let isClearEnabled: Bool
    let errorMessage: String?
    let recorderAccessibilityLabel: String
    let clearAccessibilityLabel: String

    var id: ShortcutAction { action }
}

@MainActor
struct KeyboardShortcutSettingsPresentation: Equatable {
    static let explanation =
        "The latest notification shortcut uses notifications delivered during this app run."

    let rows: [ShortcutSettingsRowPresentation]
    let explanation: String

    init(controller: ShortcutAssignmentController) {
        rows = [
            Self.row(
                title: "Toggle Herdr Menu",
                action: .toggleMenu,
                controller: controller
            ),
            Self.row(
                title: "Focus Latest Notification",
                action: .focusLatestNotification,
                controller: controller
            ),
        ]
        explanation = Self.explanation
    }

    private static func row(
        title: String,
        action: ShortcutAction,
        controller: ShortcutAssignmentController
    ) -> ShortcutSettingsRowPresentation {
        let shortcut = controller.shortcut(for: action)
        return ShortcutSettingsRowPresentation(
            action: action,
            title: title,
            displayString: controller.displayString(for: action) ?? "Unassigned",
            isClearEnabled: shortcut != nil,
            errorMessage: controller.error(for: action),
            recorderAccessibilityLabel: "\(title) shortcut recorder",
            clearAccessibilityLabel: "Clear \(title) shortcut"
        )
    }
}

struct KeyboardShortcutSettingsView: View {
    @Bindable var controller: ShortcutAssignmentController

    var body: some View {
        let presentation = KeyboardShortcutSettingsPresentation(controller: controller)

        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts work globally, including when Herdr is in the background.")
                .foregroundStyle(.secondary)

            ForEach(presentation.rows) { row in
                ShortcutSettingsRow(presentation: row, controller: controller)
            }

            Divider()

            Text(presentation.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct ShortcutSettingsRow: View {
    let presentation: ShortcutSettingsRowPresentation
    let controller: ShortcutAssignmentController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(presentation.title)
                    .frame(width: 180, alignment: .leading)

                NativeShortcutRecorder(
                    displayString: presentation.displayString,
                    accessibilityLabel: presentation.recorderAccessibilityLabel,
                    onCapture: { binding in
                        controller.assign(binding, to: presentation.action)
                    },
                    onCancel: {},
                    onClear: {
                        controller.assign(nil, to: presentation.action)
                    },
                    onInvalidBareKey: {
                        controller.rejectBareKey(for: presentation.action)
                    },
                    onRecordingChange: { isRecording in
                        controller.setRecordingActive(isRecording)
                    }
                )
                .frame(maxWidth: .infinity)

                Button("Clear") {
                    controller.assign(nil, to: presentation.action)
                }
                .disabled(!presentation.isClearEnabled)
                .accessibilityLabel(presentation.clearAccessibilityLabel)
            }

            if let errorMessage = presentation.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.leading, 192)
                    .accessibilityLabel(
                        "\(presentation.title) shortcut error: \(errorMessage)"
                    )
            }
        }
    }
}
