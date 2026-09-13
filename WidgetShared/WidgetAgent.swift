import Foundation

enum AgentWindow: String, Codable, CaseIterable, Sendable {
    case all, today, hours, days
}

struct WidgetAgent: Codable, Equatable, Identifiable, Sendable {
    let session: String
    let workspaceID: String
    let workspace: String
    let tabID: String
    var tab: String
    let paneID: String
    var agentName: String
    let agentType: String
    let status: String
    let lastMessageAt: Date?
    var id: String { session + "/" + paneID }
    var groupID: String { session + "/" + workspaceID }
    var title: String {
        let namedTab = Int(tab) == nil ? tab : ""
        let pieces = [namedTab, agentName].filter { !$0.isEmpty }
        let unique = pieces.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? (Int(tab) != nil && tab != "1" ? "Tab \(tab)" : agentType) : unique.joined(separator: " · ")
    }
    var detail: String { agentType }
    var url: URL {
        var components = URLComponents()
        components.scheme = "herdr-menubar"
        components.host = "agent"
        components.queryItems = [URLQueryItem(name: "session", value: session), URLQueryItem(name: "pane", value: paneID)]
        return components.url!
    }
    func matches(_ window: AgentWindow, amount: Int, now: Date, calendar: Calendar = .current) -> Bool {
        if window == .all { return true }
        guard let lastMessageAt, lastMessageAt <= now else { return false }
        if window == .today { return lastMessageAt >= calendar.startOfDay(for: now) }
        let interval = Double(max(1, min(amount, 8760))) * (window == .days ? 86400 : 3600)
        return lastMessageAt > now.addingTimeInterval(-interval)
    }
}

struct WidgetAgentTarget: Equatable, Sendable {
    let session: String
    let paneID: String
    init?(url: URL) {
        guard url.scheme == "herdr-menubar", url.host == "agent", url.path.isEmpty,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let sessions = items.filter { $0.name == "session" }.compactMap(\.value)
        let panes = items.filter { $0.name == "pane" }.compactMap(\.value)
        guard sessions.count == 1, panes.count == 1, !panes[0].isEmpty, panes[0].count <= 512,
              sessions[0] == "default" || sessions[0].hasPrefix("named:") else { return nil }
        session = sessions[0]
        paneID = panes[0]
    }
}

struct AgentWidgetSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let writtenAt: Date
    let agents: [WidgetAgent]
    let unavailableSessions: Int
    var isRunning = true
    static func fileURL() throws -> URL {
        try WidgetProbeRepository.shared().url.deletingLastPathComponent().appendingPathComponent("agents.json")
    }
    static func read() throws -> Self {
        let data = try Data(contentsOf: fileURL())
        guard data.count <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
}
