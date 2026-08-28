import AppKit
import SwiftUI

@MainActor
final class HerdrAppDelegate: NSObject, NSApplicationDelegate {
    typealias TerminationReply = @MainActor (NSApplication, Bool) -> Void

    private let runtime: any ApplicationRuntimeServing
    private let terminationReply: TerminationReply
    private var didFinishLaunching = false
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
        Task { await runtime.start() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await runtime.applicationDidBecomeActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !didCompleteTermination else { return .terminateNow }
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
