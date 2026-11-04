import AppKit
import Foundation

struct GhosttyTerminal: Equatable, Sendable {
    let id: String
    let title: String
}

struct GhosttyProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let launchDate: Date
}

struct GhosttyTerminalSnapshot: Equatable, Sendable {
    let process: GhosttyProcessIdentity
    let terminals: [GhosttyTerminal]
}

struct GhosttyRunningApplication: Sendable {
    let process: GhosttyProcessIdentity
    let version: String
}

enum GhosttyControlConstants {
    static let bundleIdentifier = "com.mitchellh.ghostty"
}

enum GhosttyFocusError: Error, Equatable, Sendable {
    case noAttachedClient
    case unsupportedHerdr
    case ghosttyUnavailable
    case unsupportedGhostty
    case automationDenied
    case ghosttyControlFailed
    case lookupTimedOut
    case ambiguousMarker
    case markerCleanupFailed
    case targetGone
}

protocol GhosttyTransporting: Sendable {
    func authorize(process: GhosttyProcessIdentity) async throws
    func listTerminals(process: GhosttyProcessIdentity, timeout: Duration) async throws -> [GhosttyTerminal]
    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws
}

@MainActor
protocol GhosttyControlling: Sendable {
    func prepareForFocus() async throws -> GhosttyProcessIdentity
    func listTerminals(process: GhosttyProcessIdentity, timeout: Duration) async throws -> GhosttyTerminalSnapshot
    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws
}

@MainActor
struct LiveGhosttyControl: GhosttyControlling {
    typealias RunningApplications = @MainActor @Sendable () -> [GhosttyRunningApplication]
    private let transport: any GhosttyTransporting
    private let runningApplications: RunningApplications

    init(transport: any GhosttyTransporting, runningApplications: @escaping RunningApplications) {
        self.transport = transport
        self.runningApplications = runningApplications
    }

    static func live() -> LiveGhosttyControl {
        LiveGhosttyControl(transport: LiveGhosttyAppleEventTransport()) {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: GhosttyControlConstants.bundleIdentifier
            ).map { application in
                let launchDate = application.launchDate
                let bundle = application.bundleURL.flatMap { Bundle(url: $0) }
                let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let hasIdentity = launchDate != nil && application.processIdentifier > 0
                return GhosttyRunningApplication(
                    process: GhosttyProcessIdentity(
                        pid: application.processIdentifier,
                        launchDate: launchDate ?? .distantPast
                    ),
                    version: hasIdentity ? version : ""
                )
            }
        }
    }

    func prepareForFocus() async throws -> GhosttyProcessIdentity {
        let applications = runningApplications()
        guard applications.count == 1, let application = applications.first else {
            throw GhosttyFocusError.ghosttyUnavailable
        }
        let components = application.version.split(separator: ".", omittingEmptySubsequences: false)
        let hasNumericComponents = components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
        guard components.count == 3, hasNumericComponents,
              application.version.compare("1.4.0", options: .numeric) != .orderedAscending else {
            throw GhosttyFocusError.unsupportedGhostty
        }
        try await transport.authorize(process: application.process)
        let current = runningApplications()
        guard current.count == 1, current.first?.process == application.process else {
            throw GhosttyFocusError.targetGone
        }
        return application.process
    }

    func listTerminals(process: GhosttyProcessIdentity, timeout: Duration) async throws -> GhosttyTerminalSnapshot {
        let before = runningApplications()
        guard before.count == 1, before.first?.process == process else {
            throw GhosttyFocusError.targetGone
        }
        let terminals = try await transport.listTerminals(process: process, timeout: timeout)
        let after = runningApplications()
        guard after.count == 1, after.first?.process == process else {
            throw GhosttyFocusError.targetGone
        }
        return GhosttyTerminalSnapshot(process: process, terminals: terminals)
    }

    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws {
        let current = runningApplications()
        guard current.count == 1, current.first?.process == process else {
            throw GhosttyFocusError.targetGone
        }
        try await transport.focusTerminal(id: id, process: process)
    }
}
