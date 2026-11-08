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
        return drainCompleteLines(limit: nil).lines
    }

    /// Framing that enforces `maxLineLength` when one is set. Complete lines that precede an
    /// over-cap line are returned first, together with the error. Overflow is sticky: the
    /// buffered data is discarded and every later call returns no lines and the same error.
    mutating func appendLines(_ data: Data) -> (lines: [Data], error: FramingError?) {
        if overflowed, let maxLineLength { return ([], .lineTooLong(limit: maxLineLength)) }
        pending.append(data)
        let (lines, exceeded) = drainCompleteLines(limit: maxLineLength)
        guard exceeded, let maxLineLength else { return (lines, nil) }
        overflowed = true
        pending.removeAll(keepingCapacity: false)
        return (lines, .lineTooLong(limit: maxLineLength))
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

    /// Lines completed before `limit` was exceeded (by a complete line or by the unterminated
    /// remainder), and whether it was.
    private mutating func drainCompleteLines(limit: Int?) -> (lines: [Data], exceeded: Bool) {
        var lines: [Data] = []

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newlineIndex])
            pending.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            if let limit, line.count > limit { return (lines, true) }
            if !line.isEmpty {
                lines.append(line)
            }
        }

        if let limit {
            // A trailing `\r` may still turn out to be part of a CRLF terminator.
            let remainder = pending.last == 0x0D ? pending.count - 1 : pending.count
            if remainder > limit { return (lines, true) }
        }
        return (lines, false)
    }
}
