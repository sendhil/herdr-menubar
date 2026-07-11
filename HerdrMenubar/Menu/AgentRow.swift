import SwiftUI

struct AgentRow: View {
    let item: AgentMenuItem
    let quieter: Bool
    let action: () -> Void

    init(item: AgentMenuItem, quieter: Bool = false, action: @escaping () -> Void) {
        self.item = item
        self.quieter = quieter
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: statusImage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayLabel)
                    Text("\(item.agentLabel) · \(statusLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(quieter ? 0.72 : 1)
        }
    }

    private var statusImage: String {
        switch item.status {
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .working: "ellipsis.circle"
        default: "circle"
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .blocked: "Blocked"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }
}
