import AppKit
import Foundation

struct WezTermPane: Decodable, Equatable, Sendable {
    let windowID: Int
    let tabID: Int
    let paneID: Int
    let title: String

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case title
    }
}

enum WezTermCLIError: Error, Equatable, Sendable {
    case unavailable
    case controlFailed
    case malformedOutput
}

enum WezTermCLIConstants {
    static let bundleIdentifier = "com.github.wez.wezterm"
}

@MainActor
protocol WezTermCLIControlling: Sendable {
    func listPanes(timeout: Duration) async throws -> [WezTermPane]
    func activatePane(id: Int) async throws
}

extension WezTermCLIControlling {
    func listPanes() async throws -> [WezTermPane] {
        try await listPanes(timeout: .milliseconds(500))
    }
}

@MainActor
struct LiveWezTermCLI: WezTermCLIControlling {
    typealias BundleURLResolver = @MainActor @Sendable () -> URL?

    private static let outputLimit = 256 * 1024

    private let runner: any BoundedProcessRunning
    private let fileManager: FileManager
    private let bundleURL: BundleURLResolver

    init(
        runner: any BoundedProcessRunning = BoundedProcessRunner(),
        fileManager: FileManager = .default,
        bundleURL: @escaping BundleURLResolver = {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: WezTermCLIConstants.bundleIdentifier
            )
        }
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.bundleURL = bundleURL
    }

    func listPanes(timeout: Duration) async throws -> [WezTermPane] {
        let result = try await run(ProcessInvocation(
            executableURL: try executableURL(),
            arguments: ["cli", "list", "--format", "json"],
            deadline: min(.milliseconds(500), max(.zero, timeout)),
            stdoutLimit: Self.outputLimit,
            stderrLimit: Self.outputLimit
        ))
        guard result.exitStatus == 0 else {
            throw WezTermCLIError.controlFailed
        }
        do {
            return try JSONDecoder().decode([WezTermPane].self, from: result.stdout)
        } catch {
            throw WezTermCLIError.malformedOutput
        }
    }

    func activatePane(id: Int) async throws {
        let result = try await run(ProcessInvocation(
            executableURL: try executableURL(),
            arguments: ["cli", "activate-pane", "--pane-id", String(id)],
            deadline: .seconds(1),
            stdoutLimit: Self.outputLimit,
            stderrLimit: Self.outputLimit
        ))
        guard result.exitStatus == 0 else {
            throw WezTermCLIError.controlFailed
        }
    }

    private func executableURL() throws -> URL {
        guard let applicationURL = bundleURL() else {
            throw WezTermCLIError.unavailable
        }
        let executableURL = applicationURL.appending(path: "Contents/MacOS/wezterm")
        let values: URLResourceValues
        do {
            values = try executableURL.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
            throw WezTermCLIError.unavailable
        }
        guard values.isRegularFile == true,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw WezTermCLIError.unavailable
        }
        return executableURL
    }

    private func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        do {
            return try await runner.run(invocation)
        } catch BoundedProcessError.launchFailed {
            throw WezTermCLIError.unavailable
        } catch {
            throw WezTermCLIError.controlFailed
        }
    }
}
