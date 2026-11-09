import Foundation

// Pure row construction for Rex blocks: sanitization, labels, ranking, and subtitles.
// Seen-filtering and settling are the reducer's job; these helpers only see the records they are given.

enum RexText {
    static let maxLength = 200

    /// Sanitizes Rex text shown outside the terminal: whitespace controls and separators become
    /// spaces, other control (`Cc`) and format (`Cf`, incl. bidi) characters are removed, whitespace
    /// runs collapse to one space, the ends are trimmed, and the result is cut to 200 characters.
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            switch properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate:
                continue
            default:
                break
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let result = String(scalars)
        guard result.count > maxLength else { return result }
        return String(result.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Sanitized text, or nil when absent or empty after sanitizing.
    static func sanitizedNonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let result = sanitize(text)
        return result.isEmpty ? nil : result
    }
}

/// A record as the row builder sees it: the watcher's record plus its backend-wide epoch.
struct RexRankedRecord: Equatable, Sendable {
    let record: RexRecord
    let epoch: Int
}

enum RexRows {
    static let fallbackSessionName = "Rex session"
    static let defaultBlockLabel = "shell"
    static let defaultWindowLabelPrefix = "Window "

    /// Session display name: the sanitized label, else "Rex session".
    static func sessionDisplayName(_ label: String?) -> String {
        RexText.sanitizedNonEmpty(label) ?? fallbackSessionName
    }

    /// Case-folded text for ordering, matching `AgentRow.labelOrder`.
    static func foldedLabel(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Rex session order: case-folded display name, then session id.
    static func compareSessions(_ lhs: AgentSessionDescriptor, _ rhs: AgentSessionDescriptor) -> Bool {
        let l = foldedLabel(lhs.displayName), r = foldedLabel(rhs.displayName)
        if l != r { return l < r }
        return lhs.key.rawID < rhs.key.rawID
    }

    /// An unnamed window is labeled `Window ` + the last 8 hex digits of its window id (F10).
    static func isDefaultWindowLabel(_ label: String, windowID: String?) -> Bool {
        guard let windowID else { return false }
        let hex = windowID.filter(\.isHexDigit)
        guard hex.count >= 8 else { return false }
        return label == defaultWindowLabelPrefix + hex.suffix(8)
    }

    /// The window label unless it is the default; else the block label unless it is `shell`;
    /// else the session label; else "Rex session". All sanitized.
    static func primaryLabel(block: RexViewBlock, sessionLabel: String?) -> String {
        if let raw = block.windowLabel, !isDefaultWindowLabel(raw, windowID: block.windowID),
           let label = RexText.sanitizedNonEmpty(raw) {
            return label
        }
        if let raw = block.blockLabel, raw != defaultBlockLabel, let label = RexText.sanitizedNonEmpty(raw) {
            return label
        }
        return sessionDisplayName(sessionLabel)
    }

    /// The record's `title`, else its `effective_app`, else nil. Sanitized.
    static func agentLabel(_ record: RexRecord) -> String? {
        RexText.sanitizedNonEmpty(record.title) ?? RexText.sanitizedNonEmpty(record.app)
    }

    /// `<state> · <msg>`, else `<state> · <agent label>`, else `<state>`.
    static func subtitle(_ record: RexRecord) -> String {
        if let message = RexText.sanitizedNonEmpty(record.msg) { return "\(record.state) · \(message)" }
        if let agent = agentLabel(record) { return "\(record.state) · \(agent)" }
        return record.state
    }

    /// blocked > working > error > done; idle and unknown states never rank.
    static func rank(_ state: RexProgramState) -> Int? {
        switch state {
        case .blocked: 0
        case .working: 1
        case .error: 2
        case .done: 3
        case .idle: nil
        }
    }

    static func rowState(_ state: RexProgramState) -> RowState? {
        switch state {
        case .blocked: .attention(.blocked)
        case .working: .working
        case .error: .attention(.error)
        case .done: .attention(.done)
        case .idle: nil
        }
    }

    static func attentionState(_ state: RexProgramState) -> AttentionState? {
        switch state {
        case .blocked: .blocked
        case .error: .error
        case .done: .done
        case .working, .idle: nil
        }
    }

    /// The record that decides the row: best rank, ties to the higher epoch. nil if none ranks.
    static func decidingRecord(_ records: [RexRankedRecord]) -> RexRankedRecord? {
        var best: (rank: Int, record: RexRankedRecord)?
        for candidate in records {
            guard let state = candidate.record.programState, let rank = rank(state) else { continue }
            if let current = best, current.rank < rank || (current.rank == rank && current.record.epoch >= candidate.epoch) {
                continue
            }
            best = (rank, candidate)
        }
        return best?.record
    }

    /// The row for one placed block from its visible (not seen-hidden) records; nil when none ranks.
    static func row(
        session: AgentSessionKey,
        block: RexViewBlock,
        sessionLabel: String?,
        visibleRecords: [RexRankedRecord],
        seenToken: SeenToken?
    ) -> AgentRow? {
        guard let deciding = decidingRecord(visibleRecords),
              let programState = deciding.record.programState,
              let state = rowState(programState) else { return nil }
        return AgentRow(
            target: AgentTarget(session: session, paneID: block.blockID),
            displayLabel: primaryLabel(block: block, sessionLabel: sessionLabel),
            agentLabel: agentLabel(deciding.record),
            state: state,
            subtitle: subtitle(deciding.record),
            seenToken: seenToken
        )
    }
}
