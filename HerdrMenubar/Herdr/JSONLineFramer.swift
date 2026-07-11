import Foundation

enum FramingError: Error, Equatable, Sendable {
    case incompleteLine
}

struct JSONLineFramer: Sendable {
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newlineIndex])
            pending.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }

    mutating func finish() throws {
        guard pending.allSatisfy({ byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }) else {
            throw FramingError.incompleteLine
        }
        pending.removeAll(keepingCapacity: false)
    }
}
