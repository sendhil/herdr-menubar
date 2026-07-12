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
                    Text(item.visibleLabel)
                    Text(item.secondaryLabel)
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

}
