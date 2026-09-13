import Foundation

enum AgentStatus: String, Codable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: value) ?? .unknown
    }
}

struct AgentSessionReference: Codable, Equatable, Sendable {
    let agent: String
    let kind: String
    let source: String
    let value: String
}

struct PaneInfo: Codable, Identifiable, Equatable, Sendable {
    let paneID: String
    let terminalID: String
    let workspaceID: String
    let tabID: String
    let focused: Bool
    let label: String?
    let agent: String?
    let title: String?
    let displayAgent: String?
    let agentStatus: AgentStatus
    let revision: UInt64
    var agentSession: AgentSessionReference? = nil

    var id: String { paneID }

    var displayLabel: String {
        if let title, !title.isEmpty {
            return title
        }
        if let label, !label.isEmpty {
            return label
        }
        return paneID
    }

    var agentLabel: String {
        // The public API has no internal agent_name; Herdr's observed UI uses pane labels before detected agents.
        if let displayAgent, !displayAgent.isEmpty {
            return displayAgent
        }
        if let label, !label.isEmpty {
            return label
        }
        if let agent, !agent.isEmpty {
            return agent
        }
        return "Agent"
    }

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused
        case label
        case agent
        case title
        case displayAgent = "display_agent"
        case agentStatus = "agent_status"
        case revision
        case agentSession = "agent_session"
    }
}

struct PaneListResult: Codable, Equatable, Sendable {
    let type: String
    let panes: [PaneInfo]
}

struct PaneFocusResult: Codable, Equatable, Sendable {
    let type: String
    let pane: PaneInfo
}

struct ClientWindowTitleResult: Codable, Equatable, Sendable {
    let type: String
    let changed: Bool
    let reason: String

    var hasForegroundClient: Bool { reason != "no_foreground_client" }
}

struct WorkspaceInfo: Codable, Equatable, Sendable {
    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let tabCount: Int
    let activeTabID: String
    let agentStatus: AgentStatus

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
    }
}

struct WorkspaceListResult: Codable, Equatable, Sendable {
    let type: String
    let workspaces: [WorkspaceInfo]
}

struct TabInfo: Codable, Equatable, Sendable {
    let tabID: String
    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let agentStatus: AgentStatus

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}

struct TabListResult: Codable, Equatable, Sendable {
    let type: String
    let tabs: [TabInfo]
}

struct PresentationSnapshot: Equatable, Sendable {
    let panes: [PaneInfo]
    let workspaces: [WorkspaceInfo]
    let tabs: [TabInfo]
}

struct EventEnvelope: Codable, Equatable, Sendable {
    let event: String
    let data: EventData
}

struct EventData: Codable, Equatable, Sendable {
    let paneID: String?
    let workspaceID: String?
    let agentStatus: AgentStatus?

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
    }
}

struct HerdrAPIError: Codable, LocalizedError, Equatable, Sendable {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

struct HerdrResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let id: String
    let result: Result?
    let error: HerdrAPIError?
}

struct HerdrRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    let id: String
    let method: String
    let params: Params
}

struct EmptyParams: Codable, Equatable, Sendable {
    init() {}
}

struct PaneTargetParams: Codable, Equatable, Sendable {
    let paneID: String

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
    }
}

struct ClientWindowTitleSetParams: Codable, Equatable, Sendable {
    let title: String
}

struct TabListParams: Codable, Equatable, Sendable {
    let workspaceID: String?

    init(workspaceID: String? = nil) {
        self.workspaceID = workspaceID
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}
