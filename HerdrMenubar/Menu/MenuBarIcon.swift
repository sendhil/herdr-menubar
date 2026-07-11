import SwiftUI

struct MenuBarIcon: View {
    let connectionState: ConnectionState
    let attentionCount: Int

    var body: some View {
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
}
