import Foundation

/// One "the user viewed this result in Rex" receipt, reduced to the only three fields used: the
/// full block id, the record id (`""` for the root), and the date truncated to milliseconds.
/// Rex's other receipt fields can hold private text and are never read.
struct RexViewReceipt: Hashable, Sendable {
    let blockID: String
    let recordID: String
    let millis: Int64

    /// `updated_at` (microseconds) truncated to the receipt's millisecond precision.
    static func millis(fromMicroseconds micros: Int64) -> Int64 {
        micros >= 0 ? micros / 1000 : -((-micros + 999) / 1000)
    }
}

/// Reads Rex's viewed receipts, read-only. `nil` means unavailable, malformed, or oversized:
/// the caller then acknowledges nothing.
protocol RexViewReceiptReading: Sendable {
    func readReceipts() -> [RexViewReceipt]?
}

enum RexViewReceiptParser {
    /// More receipts than this is treated as an unexpected shape (unavailable).
    static let maxReceipts = 2000

    /// Expects `{receipts: [{block: String, record: String, date: Date, ...}]}`. Any entry of
    /// the wrong shape makes the whole snapshot unavailable.
    static func parse(_ value: Any?) -> [RexViewReceipt]? {
        guard let root = value as? [String: Any], let entries = root["receipts"] as? [Any],
              entries.count <= maxReceipts else { return nil }
        var result: [RexViewReceipt] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            guard let dict = entry as? [String: Any],
                  let block = dict["block"] as? String,
                  let record = dict["record"] as? String,
                  let date = dict["date"] as? Date else { return nil }
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, abs(seconds) < 1e11 else { return nil }
            result.append(RexViewReceipt(blockID: block, recordID: record, millis: Int64((seconds * 1000).rounded())))
        }
        return result
    }
}

/// Reads `Workspace.programActivitySeen` from Rex's preferences domain. Only reads: never
/// synchronizes, writes, or flushes.
struct LiveRexViewReceiptReader: RexViewReceiptReading {
    static let domain = "com.superlogical.rex"
    static let key = "Workspace.programActivitySeen"

    func readReceipts() -> [RexViewReceipt]? {
        RexViewReceiptParser.parse(CFPreferencesCopyAppValue(Self.key as CFString, Self.domain as CFString))
    }
}
