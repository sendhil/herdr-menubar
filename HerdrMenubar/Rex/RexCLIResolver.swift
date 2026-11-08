import AppKit
import Foundation

/// Output of `rex version`: `rex <version>-g<sha>` … `api: revision N (supports 0 to N)` (F14).
struct RexCLIVersionInfo: Equatable, Sendable {
    static let minimumAPIRevision = 10

    let version: String
    let apiRevision: Int

    /// Requires both the `rex <version>` line (version = up to the first space) and the
    /// `api: revision <N>` line.
    static func parse(_ output: String) -> RexCLIVersionInfo? {
        var version: String?
        var revision: Int?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if version == nil, line.hasPrefix("rex ") {
                let rest = line.dropFirst(4)
                let token = rest.prefix { $0 != " " }
                if !token.isEmpty { version = String(token) }
            } else if revision == nil, line.hasPrefix("api:") {
                let words = line.dropFirst(4).split(separator: " ")
                if words.count >= 2, words[0] == "revision", let number = Int(words[1]) { revision = number }
            }
        }
        guard let version, let revision else { return nil }
        return RexCLIVersionInfo(version: version, apiRevision: revision)
    }
}

/// The parts of `rex --autostart=false server status --json` the resolver uses.
struct RexServerStatus: Equatable, Sendable {
    let rexVersion: String
    let apiRevision: Int?

    /// nil unless stdout is a JSON object with a string `rex_version`.
    static func parse(_ stdout: Data) -> RexServerStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let version = object["rex_version"] as? String else { return nil }
        return RexServerStatus(rexVersion: version, apiRevision: object["api_revision"] as? Int)
    }
}

/// A validated `rex` binary.
struct RexCLI: Equatable, Sendable {
    let path: String
    let version: String
    let apiRevision: Int

    /// Lives in `…/RexServer/Versions/Current/`.
    var isCurrent: Bool { path.contains("/Versions/Current/") }
}

enum RexCLIResolution: Equatable, Sendable {
    /// Server reachable; `cli` matches its version (or is the best fallback).
    case ready(RexCLI)
    /// A valid CLI exists but `server status` failed (exit 1 when the server is down, F15) or
    /// printed no `rex_version`. Retry after 60 seconds.
    case serverUnreachable(RexCLI)
    /// No valid CLI and none was ever found in this run → `.backendHidden`, recheck every 5 minutes.
    case hidden
    /// No valid CLI now, but one was found earlier in this run → `.backendUnavailable(reason)`
    /// (normal watcher backoff), so a Rex update does not drop history.
    case unavailable(String)

    var cli: RexCLI? {
        switch self {
        case .ready(let cli), .serverUnreachable(let cli): cli
        case .hidden, .unavailable: nil
        }
    }

    /// Spec'd fixed retry interval, or nil when the backend's normal backoff applies.
    var retryInterval: Duration? {
        switch self {
        case .serverUnreachable: .seconds(60)
        case .hidden: .seconds(300)
        case .ready, .unavailable: nil
        }
    }
}

protocol RexFileSystem: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
    /// Entry names; empty when the directory is missing or unreadable.
    func contentsOfDirectory(atPath path: String) -> [String]
}

struct LiveRexFileSystem: RexFileSystem {
    func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

/// Finds the `rex` binary to drive (spec "CLI resolution"). Create one per app launch: the
/// login-shell probe runs at most once per instance, and "ever resolved" and failed candidates
/// are remembered per instance. Callers serialize `resolve()` calls.
actor RexCLIResolver {
    static let rexAppBundleIdentifier = "com.superlogical.rex"
    static let versionArguments = ["version"]
    static let serverStatusArguments = ["--autostart=false", "server", "status", "--json"]
    static let fixedCandidates = ["/opt/homebrew/bin/rex", "/usr/local/bin/rex"]
    static let defaultLoginShell = "/bin/zsh"

    private let configuredPath: String?
    private let homeDirectory: String
    private let loginShell: String?
    private let isRexAppInstalled: @Sendable () -> Bool
    private let fileSystem: RexFileSystem
    private let runner: ProcessRunning

    private var shellProbeRan = false
    private var shellProbePath: String?
    private(set) var hasEverResolved = false
    private(set) var failedPaths: Set<String> = []

    init(
        configuredPath: String?,
        homeDirectory: String = NSHomeDirectory(),
        loginShell: String? = ProcessInfo.processInfo.environment["SHELL"],
        isRexAppInstalled: @escaping @Sendable () -> Bool = RexCLIResolver.liveIsRexAppInstalled,
        fileSystem: RexFileSystem = LiveRexFileSystem(),
        runner: ProcessRunning = LiveProcessRunner()
    ) {
        self.configuredPath = configuredPath
        self.homeDirectory = homeDirectory
        self.loginShell = loginShell
        self.isRexAppInstalled = isRexAppInstalled
        self.fileSystem = fileSystem
        self.runner = runner
    }

    static let liveIsRexAppInstalled: @Sendable () -> Bool = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rexAppBundleIdentifier) != nil
    }

    /// Remember a binary whose watcher exited on its own before `snapshot_done` with an exit
    /// code other than 4 (not timeouts, not our own termination). It is skipped until every
    /// valid candidate has failed, then the list is cleared.
    func markFailed(path: String) {
        failedPaths.insert(path)
    }

    /// Throws `CancellationError` if cancelled; state is then unchanged except for a completed
    /// shell probe.
    func resolve() async throws -> RexCLIResolution {
        // 1. An explicit `rexCLIPath` wins when it validates.
        if let configuredPath, fileSystem.isExecutableFile(atPath: configuredPath),
           let cli = try await validate(configuredPath) {
            return try await finish(choosingAmong: [cli], configured: true)
        }

        // 2. Versioned and fixed candidates, then (only if none exist) the login-shell probe.
        var paths = automaticCandidates().filter { $0 != configuredPath }
        if paths.isEmpty, let probed = try await shellProbe(), fileSystem.isExecutableFile(atPath: probed) {
            paths = [probed]
        }

        // 3. Validate every candidate.
        var valid: [RexCLI] = []
        for path in paths {
            if let cli = try await validate(path) { valid.append(cli) }
        }
        guard !valid.isEmpty else {
            return hasEverResolved ? .unavailable("Rex command-line tool not found") : .hidden
        }

        // 5. Skip failed candidates until none are left, then clear the list.
        var usable = valid.filter { !failedPaths.contains($0.path) }
        if usable.isEmpty {
            failedPaths.removeAll()
            usable = valid
        }
        return try await finish(choosingAmong: usable, configured: false)
    }

    /// `…/Versions/*/Rex Server.app/Contents/MacOS/rex` (Current first, then numbered builds
    /// newest first, then other names), then Homebrew and local paths. Existing executables only.
    nonisolated func automaticCandidates() -> [String] {
        let versionsDirectory = homeDirectory + "/Library/Application Support/com.superlogical.rex/RexServer/Versions"
        let directories = fileSystem.contentsOfDirectory(atPath: versionsDirectory)
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                func rank(_ name: String) -> (Int, Int, String) {
                    if name == "Current" { return (0, 0, name) }
                    if let number = Int(name) { return (1, -number, name) }
                    return (2, 0, name)
                }
                return rank(a) < rank(b)
            }
        let versioned = directories.map { "\(versionsDirectory)/\($0)/Rex Server.app/Contents/MacOS/rex" }
        let fixed = Self.fixedCandidates + [homeDirectory + "/.local/bin/rex"]
        return (versioned + fixed).filter { fileSystem.isExecutableFile(atPath: $0) }
    }

    // MARK: Steps

    private func validate(_ path: String) async throws -> RexCLI? {
        let result = await runner.run(ProcessRequest(executable: path, arguments: Self.versionArguments,
                                                     timeout: RexTimeouts.version))
        try Self.checkCancelled(result)
        guard result.exitCode == 0,
              let info = RexCLIVersionInfo.parse(result.stdoutText),
              info.apiRevision >= RexCLIVersionInfo.minimumAPIRevision else { return nil }
        return RexCLI(path: path, version: info.version, apiRevision: info.apiRevision)
    }

    /// 4. Ask the server which version it runs, using the first usable candidate.
    private func finish(choosingAmong candidates: [RexCLI], configured: Bool) async throws -> RexCLIResolution {
        let first = candidates[0]
        let result = await runner.run(ProcessRequest(executable: first.path, arguments: Self.serverStatusArguments,
                                                     timeout: RexTimeouts.serverStatus))
        try Self.checkCancelled(result)
        hasEverResolved = true

        guard result.exitCode == 0, let status = RexServerStatus.parse(result.stdout) else {
            return .serverUnreachable(candidates.first(where: \.isCurrent) ?? first)
        }
        if configured { return .ready(first) }
        if let match = candidates.first(where: { $0.version == status.rexVersion }) { return .ready(match) }
        if let current = candidates.first(where: \.isCurrent) { return .ready(current) }
        let best = candidates.reduce(first) { $1.apiRevision > $0.apiRevision ? $1 : $0 }
        return .ready(best)
    }

    /// `$SHELL -lc 'command -v rex'`, only when Rex.app is installed, at most once per instance,
    /// in its own process group (killed as a group on timeout or cancellation).
    private func shellProbe() async throws -> String? {
        if shellProbeRan { return shellProbePath }
        guard isRexAppInstalled() else { return nil }
        let shell = loginShell.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultLoginShell
        var request = ProcessRequest(executable: shell, arguments: ["-lc", "command -v rex"], timeout: RexTimeouts.shellProbe)
        request.newProcessGroup = true
        let result = await runner.run(request)
        try Self.checkCancelled(result)
        shellProbeRan = true
        if result.exitCode == 0 {
            // Login shells may print banners; the answer is the last absolute path printed.
            shellProbePath = result.stdoutText.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") }
        }
        return shellProbePath
    }

    private static func checkCancelled(_ result: ProcessResult) throws {
        if result.outcome == .cancelled || Task.isCancelled { throw CancellationError() }
    }
}
