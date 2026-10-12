import AppKit

struct SketchyBarSnapshot: Codable, Equatable {
    var schemaVersion = 1
    let writtenAt: TimeInterval
    let isRunning: Bool
    let mode: String
    let attentionCount: Int
    let summary: String
}

/// A separate, aggregate-only feed; independent of widgets and their opt-in.
@MainActor
final class SketchyBarStatusPublisher {
    static let notificationName = Notification.Name("dev.herdr.menubar.statusChanged")
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Herdr Menubar/sketchybar-status.json")

    private let now: () -> TimeInterval
    private let writeSnapshot: (SketchyBarSnapshot) throws -> Void
    private let notify: () -> Void
    private let automaticHeartbeat: Bool
    private var timer: Task<Void, Never>?
    private var latest: StatusItemPresentation?
    private var published: SketchyBarSnapshot?
    private var started = false
    private var stopped = false

    init(
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        write: @escaping (SketchyBarSnapshot) throws -> Void = { try SketchyBarStatusPublisher.write($0, to: SketchyBarStatusPublisher.fileURL) },
        notify: @escaping () -> Void = {
            DistributedNotificationCenter.default().postNotificationName(
                SketchyBarStatusPublisher.notificationName, object: nil, userInfo: nil, deliverImmediately: true
            )
        },
        automaticHeartbeat: Bool = true
    ) {
        self.now = now
        self.writeSnapshot = write
        self.notify = notify
        self.automaticHeartbeat = automaticHeartbeat
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        if latest != nil { publish(running: true) }
        guard automaticHeartbeat else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, !self.stopped else { return }
                self.heartbeat()
            }
        }
    }

    func apply(_ presentation: StatusItemPresentation) {
        guard !stopped else { return }
        latest = presentation
        guard started else { return }
        let record = snapshot(running: true)
        if let published, let record,
           published.mode == record.mode,
           published.attentionCount == record.attentionCount,
           published.summary == record.summary { return }
        publish(running: true)
    }

    func heartbeat() {
        guard started, !stopped else { return }
        publish(running: true)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        if started { publish(running: false) }
    }

    private func snapshot(running: Bool) -> SketchyBarSnapshot? {
        guard let latest else { return nil }
        let mode: String
        switch latest.icon.mode {
        case .disconnected: mode = "disconnected"
        case .clear: mode = "clear"
        case .attention: mode = "attention"
        }
        return SketchyBarSnapshot(writtenAt: now(), isRunning: running, mode: mode,
                                 attentionCount: max(0, latest.icon.attentionCount), summary: latest.accessibilityValue)
    }

    private func publish(running: Bool) {
        guard let record = snapshot(running: running) else { return }
        do {
            try writeSnapshot(record)
            published = record
            notify()
        } catch {
            // Retry the latest state on the next update or heartbeat.
            NSLog("Herdr Menubar: could not publish SketchyBar status: %@", error.localizedDescription)
        }
    }

    static func write(_ snapshot: SketchyBarSnapshot, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // A private staging file is renamed within the same directory, so readers
        // see a complete JSON document and the final file is never world-readable.
        let temporary = directory.appendingPathComponent(".status-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(snapshot)
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
