import Foundation
@testable import HerdrMenubar

// Test-only shims that keep Herdr-shaped tests readable after the backend migration.

extension AgentSessionKey {
    static var `default`: AgentSessionKey { AgentSessionKey(herdr: .default) }
    static func named(_ name: String) -> AgentSessionKey { AgentSessionKey(herdr: .named(name)) }
}

extension SelectionTarget {
    /// Herdr targets only.
    var sessionID: SessionID { target.session.herdrSessionID! }
    var paneID: String { target.paneID }
}
