import SwiftUI

struct MenuBarIconPresentation: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case disconnected
        case clear
        case attention
    }

    let mode: Mode
    let opacity: Double
    let attentionCount: Int
    let showsAttentionCount: Bool

    init(connectionState: ConnectionState, attentionCount: Int) {
        self.attentionCount = attentionCount
        switch connectionState {
        case .searching, .noSessions, .connecting:
            mode = .disconnected
            opacity = 0.55
            showsAttentionCount = false
        case .connected where attentionCount > 0:
            mode = .attention
            opacity = 1
            showsAttentionCount = true
        case .connected:
            mode = .clear
            opacity = 1
            showsAttentionCount = false
        }
    }
}

struct MenuBarIcon: View {
    let connectionState: ConnectionState
    let attentionCount: Int

    static func accessibilityValue(
        connectionState: ConnectionState,
        attentionCount: Int
    ) -> String {
        switch connectionState {
        case .searching:
            return "Searching for Herdr sessions"
        case .noSessions:
            return "No Herdr sessions running"
        case .connecting:
            return "Connecting to Herdr sessions"
        case .connected where attentionCount == 0:
            return "Connected, no agents need attention"
        case .connected where attentionCount == 1:
            return "Connected, 1 agent needs attention"
        case .connected:
            return "Connected, \(attentionCount) agents need attention"
        }
    }

    var body: some View {
        let presentation = MenuBarIconPresentation(
            connectionState: connectionState,
            attentionCount: attentionCount
        )

        HStack(spacing: 2) {
            TerminalStatusIcon()

            if presentation.showsAttentionCount {
                Text("\(attentionCount)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .opacity(presentation.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Herdr")
        .accessibilityValue(Self.accessibilityValue(
            connectionState: connectionState,
            attentionCount: attentionCount
        ))
    }
}

private struct TerminalStatusIcon: View {
    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 16, weight: .regular))
    }
}
