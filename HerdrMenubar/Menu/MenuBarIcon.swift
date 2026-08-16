import SwiftUI

struct MenuBarIconPresentation: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case disconnected
        case clear
        case attention
    }

    enum LightStyle: Equatable, Sendable {
        case hollow
        case solid
        case emphasizedSolid
    }

    let mode: Mode
    let lightStyle: LightStyle
    let opacity: Double
    let showsAttentionCount: Bool

    init(connectionState: ConnectionState, attentionCount: Int) {
        switch connectionState {
        case .searching, .noSessions, .connecting:
            mode = .disconnected
            lightStyle = .hollow
            opacity = 0.55
            showsAttentionCount = false
        case .connected where attentionCount > 0:
            mode = .attention
            lightStyle = .emphasizedSolid
            opacity = 1
            showsAttentionCount = true
        case .connected:
            mode = .clear
            lightStyle = .solid
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
            TerminalStatusIcon(lightStyle: presentation.lightStyle)

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
    let lightStyle: MenuBarIconPresentation.LightStyle

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 16, weight: .regular))
            .overlay(alignment: .topTrailing) {
                statusLight
                    .padding(.top, 2)
                    .padding(.trailing, 1.5)
            }
    }

    @ViewBuilder
    private var statusLight: some View {
        switch lightStyle {
        case .hollow:
            Circle()
                .stroke(lineWidth: 1)
                .frame(width: 4, height: 4)
        case .solid:
            Circle()
                .frame(width: 3.5, height: 3.5)
        case .emphasizedSolid:
            Circle()
                .frame(width: 5, height: 5)
        }
    }
}
