import Foundation

struct WidgetProbeRepository: Sendable {
    let url: URL

    static func shared(bundle: Bundle = .main) throws -> Self {
        guard let group = bundle.object(forInfoDictionaryKey: "HerdrWidgetAppGroup") as? String,
              !group.hasPrefix("."), !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return Self(url: container.appendingPathComponent("widget-probe.json"))
    }

    func write(_ snapshot: WidgetProbeSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    func read() throws -> WidgetProbeSnapshot {
        let snapshot = try JSONDecoder().decode(WidgetProbeSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        return snapshot
    }
}
