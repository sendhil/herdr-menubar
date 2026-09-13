import SwiftUI
import WidgetKit
import OSLog

private let logger = Logger(subsystem: "dev.herdr.menubar.widgets", category: "refresh-probe")

struct ProbeEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetProbeSnapshot?
    let readAt: Date
    let isPreview: Bool
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: .now, snapshot: nil, readAt: .now, isPreview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        let current = readEntry()
        var entries = [current]
        if let snapshot = current.snapshot, snapshot.isFresh(at: current.date) {
            let expiration = snapshot.writtenAt.addingTimeInterval(WidgetProbeSnapshot.freshnessInterval)
            entries.append(ProbeEntry(date: expiration, snapshot: snapshot, readAt: current.readAt, isPreview: false))
        }
        completion(Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(300))))
    }

    private func readEntry() -> ProbeEntry {
        let now = Date.now
        do {
            let snapshot = try WidgetProbeRepository.shared().read()
            logger.notice("read generation=\(snapshot.generation.uuidString, privacy: .public) sequence=\(snapshot.sequence) readAt=\(now.timeIntervalSince1970) writtenAt=\(snapshot.writtenAt.timeIntervalSince1970)")
            return ProbeEntry(date: now, snapshot: snapshot, readAt: now, isPreview: false)
        } catch {
            logger.error("Shared snapshot unavailable: \(error.localizedDescription, privacy: .public)")
            return ProbeEntry(date: now, snapshot: nil, readAt: now, isPreview: false)
        }
    }
}

struct ProbeView: View {
    let entry: ProbeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "terminal.fill")
                Text("Herdr").font(.headline)
                Spacer()
                Text("REFRESH PROBE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let snapshot = entry.snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%02d", snapshot.sequence)).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.isFresh(at: entry.date) ? "Snapshot received" : "Snapshot is old").font(.subheadline)
                        Text(String(snapshot.generation.uuidString.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Label(snapshot.writtenAt.formatted(date: .omitted, time: .standard), systemImage: "arrow.up.circle")
                    Spacer()
                    Label(entry.readAt.formatted(date: .omitted, time: .standard), systemImage: "arrow.down.circle")
                }.font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(entry.isPreview ? "Native desktop updates" : "No snapshot yet").font(.title3.weight(.medium))
                Text(entry.isPreview ? "A small test of Herdr’s widget refresh path." : "Start Herdr with the refresh probe enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }
}

struct HerdrRefreshProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HerdrRefreshProbe", provider: ProbeProvider()) { ProbeView(entry: $0) }
            .configurationDisplayName("Herdr refresh probe")
            .description("Verify native desktop updates before enabling agent widgets.")
            .supportedFamilies([.systemMedium])
    }
}

@main
struct HerdrWidgets: WidgetBundle {
    var body: some Widget {
        HerdrAgentWidget()
        HerdrRefreshProbeWidget()
    }
}
