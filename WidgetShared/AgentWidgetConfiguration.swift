import AppIntents

extension AgentWindow: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Message window"
    static let caseDisplayRepresentations: [AgentWindow: DisplayRepresentation] = [
        .all: "All agents", .today: "Today", .hours: "Last hours", .days: "Last days"
    ]
}

struct AgentWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Herdr agents"
    static let description = IntentDescription("Show agents you messaged within a chosen window.")
    @Parameter(title: "Message window", default: .all) var window: AgentWindow
    @Parameter(title: "Number of hours or days", default: 24, inclusiveRange: (1, 8760)) var amount: Int
}
