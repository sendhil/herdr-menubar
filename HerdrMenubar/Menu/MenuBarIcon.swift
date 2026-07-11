import SwiftUI

struct MenuBarIcon: View {
    let connectionState: ConnectionState
    let attentionCount: Int

    static func accessibilityValue(
        connectionState: ConnectionState,
        attentionCount: Int
    ) -> String {
        switch connectionState {
        case .disconnected:
            return "Disconnected"
        case .connected where attentionCount == 0:
            return "Connected, no agents need attention"
        case .connected where attentionCount == 1:
            return "Connected, 1 agent needs attention"
        case .connected:
            return "Connected, \(attentionCount) agents need attention"
        }
    }

    var body: some View {
        Group {
            switch connectionState {
            case .disconnected:
                Image(systemName: "circle.dotted")
                    .opacity(0.55)
            case .connected where attentionCount == 0:
                Image(systemName: "circle")
            case .connected:
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("\(attentionCount)")
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Herdr")
        .accessibilityValue(Self.accessibilityValue(
            connectionState: connectionState,
            attentionCount: attentionCount
        ))
    }
}
