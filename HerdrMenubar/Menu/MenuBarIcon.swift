import SwiftUI

/// User-visible product wording. `.agents` is used only while Rex is active.
enum AgentWording: Equatable, Sendable {
    case herdr
    case agents

    var accessibilityLabel: String {
        switch self {
        case .herdr: "Herdr"
        case .agents: "Agents"
        }
    }

    var tooltipPrefix: String { "\(accessibilityLabel) — " }

    var symbolDescription: String {
        switch self {
        case .herdr: "Herdr terminal status"
        case .agents: "Agent status"
        }
    }

    var sessionsNoun: String {
        switch self {
        case .herdr: "Herdr sessions"
        case .agents: "agent sessions"
        }
    }
}

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
    let wording: AgentWording

    init(connectionState: ConnectionState, attentionCount: Int, wording: AgentWording = .herdr) {
        self.attentionCount = attentionCount
        self.wording = wording
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
    var wording: AgentWording = .herdr

    static func accessibilityValue(
        connectionState: ConnectionState,
        attentionCount: Int,
        wording: AgentWording = .herdr
    ) -> String {
        switch connectionState {
        case .searching:
            return "Searching for \(wording.sessionsNoun)"
        case .noSessions:
            return "No \(wording.sessionsNoun) running"
        case .connecting:
            return "Connecting to \(wording.sessionsNoun)"
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
            attentionCount: attentionCount,
            wording: wording
        )

        HStack(spacing: 2) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .regular))

            if presentation.showsAttentionCount {
                Text("\(attentionCount)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .opacity(presentation.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wording.accessibilityLabel)
        .accessibilityValue(Self.accessibilityValue(
            connectionState: connectionState,
            attentionCount: attentionCount,
            wording: wording
        ))
    }
}
