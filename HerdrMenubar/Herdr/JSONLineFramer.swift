import Foundation

enum FramingError: Error, Equatable, Sendable {
    case incompleteLine
    /// A line (excluding its terminator) grew past the framer's `maxLineLength`.
    case lineTooLong(limit: Int)
}

struct JSONLineFramer: Sendable {
    /// Opt-in cap on one line's length in bytes, excluding `\n` and a trailing `\r`.
    /// Enforced only by `appendLines(_:)`; `nil` means unlimited (Herdr's framer).
    let maxLineLength: Int?

    private var pending = Data()
    private var overflowed = false

    init(maxLineLength: Int? = nil) {
        self.maxLineLength = maxLineLength
    }

    /// Unlimited framing, unchanged from before `maxLineLength` existed. Never enforces a cap.
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        return drainCompleteLines(limit: nil) ?? []
    }

    /// Framing that enforces `maxLineLength` when one is set. Overflow is a framing error and is
    /// sticky: the buffered data is discarded and every later call throws the same error.
    mutating func appendLines(_ data: Data) throws(FramingError) -> [Data] {
        if overflowed, let maxLineLength { throw .lineTooLong(limit: maxLineLength) }
        pending.append(data)
        guard let lines = drainCompleteLines(limit: maxLineLength) else {
            overflowed = true
            pending.removeAll(keepingCapacity: false)
            throw .lineTooLong(limit: maxLineLength ?? 0)
        }
        return lines
    }

    mutating func finish() throws(FramingError) {
        if overflowed, let maxLineLength { throw .lineTooLong(limit: maxLineLength) }
        guard pending.allSatisfy({ byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }) else {
            throw .incompleteLine
        }
        pending.removeAll(keepingCapacity: false)
    }

    /// Returns nil when `limit` is exceeded by a complete line or by the unterminated remainder.
    private mutating func drainCompleteLines(limit: Int?) -> [Data]? {
        var lines: [Data] = []

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newlineIndex])
            pending.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            if let limit, line.count > limit { return nil }
            if !line.isEmpty {
                lines.append(line)
            }
        }

        if let limit {
            // A trailing `\r` may still turn out to be part of a CRLF terminator.
            let remainder = pending.last == 0x0D ? pending.count - 1 : pending.count
            if remainder > limit { return nil }
        }
        return lines
    }
}
