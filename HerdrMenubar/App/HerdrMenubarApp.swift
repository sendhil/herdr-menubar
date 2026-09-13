import AppKit
import SwiftUI

@MainActor
final class HerdrAppDelegate: NSObject, NSApplicationDelegate {
    typealias TerminationReply = @MainActor (NSApplication, Bool) -> Void

    private let runtime: any ApplicationRuntimeServing
    private let terminationReply: TerminationReply
    private var didFinishLaunching = false
    private var widgetProbe: WidgetProbePublisher?
    private var terminationTask: Task<Void, Never>?
    private var pendingTerminationSenders: [NSApplication] = []
    private var didCompleteTermination = false

    override convenience init() {
        self.init(runtime: ApplicationRuntime.live())
    }

    init(
        runtime: any ApplicationRuntimeServing,
        terminationReply: @escaping TerminationReply = {
            $0.reply(toApplicationShouldTerminate: $1)
        }
    ) {
        self.runtime = runtime
        self.terminationReply = terminationReply
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        let process = ProcessInfo.processInfo
        if WidgetProbePublisher.shouldRun(arguments: process.arguments, environment: process.environment) {
            let probe = WidgetProbePublisher.live()
            widgetProbe = probe
            probe.start(interval: process.arguments.contains("--widget-refresh-probe-fast") ? .seconds(5) : .seconds(30))
        }
        Task { await runtime.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Task { await runtime.openWidgetURL(url) } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await runtime.applicationDidBecomeActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !didCompleteTermination else { return .terminateNow }
        widgetProbe?.stop()
        pendingTerminationSenders.append(sender)
        if terminationTask == nil {
            terminationTask = Task { [weak self] in
                guard let self else { return }
                await runtime.stop()
                completeTermination()
            }
        }
        return .terminateLater
    }

    private func completeTermination() {
        guard !didCompleteTermination else { return }
        didCompleteTermination = true
        let senders = pendingTerminationSenders
        pendingTerminationSenders.removeAll()
        terminationTask = nil
        senders.forEach { terminationReply($0, true) }
    }
}

@main
struct HerdrMenubarApp: App {
    @NSApplicationDelegateAdaptor(HerdrAppDelegate.self) private var appDelegate

    static func shouldStartSynchronization(environment: [String: String]) -> Bool {
        ApplicationRuntime.shouldStartSynchronization(environment: environment)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
