import Foundation
import WidgetKit
import OSLog

@MainActor
final class WidgetProbePublisher {
    private let write: (WidgetProbeSnapshot) throws -> Void
    private let reload: () -> Void
    private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "dev.herdr.menubar", category: "refresh-probe")

    init(write: @escaping (WidgetProbeSnapshot) throws -> Void, reload: @escaping () -> Void) {
        self.write = write
        self.reload = reload
    }

    static func shouldRun(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--widget-refresh-probe") && environment["XCTestConfigurationFilePath"] == nil
    }

    static func live() -> WidgetProbePublisher {
        WidgetProbePublisher(
            write: { try WidgetProbeRepository.shared().write($0) },
            reload: { WidgetCenter.shared.reloadTimelines(ofKind: "HerdrRefreshProbe") }
        )
    }

    func publish(sequence: Int, now: Date) throws {
        let snapshot = WidgetProbeSnapshot(schemaVersion: 1, generation: UUID(), sequence: sequence, writtenAt: now)
        try write(snapshot)
        Self.logger.notice("write generation=\(snapshot.generation.uuidString, privacy: .public) sequence=\(sequence) writtenAt=\(now.timeIntervalSince1970)")
        reload()
    }

    func start(interval: Duration = .seconds(30)) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for sequence in 1...30 {
                guard !Task.isCancelled, let self else { return }
                do {
                    try self.publish(sequence: sequence, now: .now)
                } catch {
                    Self.logger.error("Probe write failed: \(error.localizedDescription, privacy: .public)")
                }
                if sequence < 30 {
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
