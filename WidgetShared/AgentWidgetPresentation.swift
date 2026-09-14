import Foundation

/// Accounts for both rows and workspace headings, preserving the filtered order.
/// Heights match AgentWidgetView; content height excludes WidgetKit's margins.
struct AgentWidgetPresentation {
    let shown: [WidgetAgent]
    let overflow: Int
    let blockedCount: Int
    let workingCount: Int
    let otherCount: Int

    init(agents: [WidgetAgent], large: Bool, availableHeight: Double) {
        blockedCount = agents.filter { $0.status == "blocked" }.count
        workingCount = agents.filter { $0.status == "working" }.count
        otherCount = agents.count - blockedCount - workingCount

        let budget = max(0, availableHeight - (large ? 76 : 58))
        var used = 0.0
        var visible: [WidgetAgent] = []
        for agent in agents {
            let heading = large && visible.last?.groupID != agent.groupID ? 18.0 : 0
            let cost = (large ? 26.0 : 30.0) + heading
            guard used + cost <= budget else { break }
            visible.append(agent)
            used += cost
        }
        shown = visible
        overflow = agents.count - visible.count
    }
}
