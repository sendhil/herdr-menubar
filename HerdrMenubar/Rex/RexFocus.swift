import Foundation

// Two-step Rex focus (spec "Focus"): `focusServer` focuses the block on the server through a
// one-shot `rex do -s <session> -e <script>`; `activate` switches the local Rex app to the
// session (`-C <client> do session.select`) and brings Rex.app forward. Pure argv building and
// result mapping live in `RexFocus`; the actor extension runs the processes.

/// One entry of `rex client ls --json` (F13).
struct RexClient: Equatable, Sendable {
    let id: String
    let kind: String?
    let platform: String?
    let label: String?
    let connectionState: String?
}

enum RexFocus {
    static let script = """
    local r, err = rex.session.focus_block{ block_id = rex.args.block }
    print(rex.json.encode(r and { focus = "ok" } or { focus = "error", err = tostring(err) }))
    """

    static let clientListArguments = ["--autostart=false", "client", "ls", "--json"]
    static let remoteControlOffMarker = "not accepting actions"
    static let notFoundMarker = "code=not_found"

    // MARK: Messages

    static let rexNotRunning = "Rex is not running"
    static let noClientRexRunning = "Rex app is not connected to the server."
    static let noClientRexNotRunning = "Rex is not running."
    static let remoteControlOff = "Turn on Remote Control in Rex Settings → Rex Server to switch sessions."
    static let appDisconnected = "Rex app disconnected."
    static let timedOut = "Rex did not respond in time"

    static func paneGone(_ session: String) -> String { "That pane no longer exists in \(session)" }
    static func sessionGone(_ session: String) -> String { "\(session) is no longer running in Rex" }

    // MARK: Arguments

    /// `rex --autostart=false do -s <session_id> --args '{"block":"<block_id>"}' -e '<script>'`.
    /// Ids travel only through `--args` JSON.
    static func focusArguments(sessionID: String, blockID: String) -> [String] {
        ["--autostart=false", "do", "-s", sessionID, "--args", json(["block": blockID]), "-e", script]
    }

    /// `rex --autostart=false -C <client_id> do session.select --args '{"session_id":"<id>"}'`.
    static func selectArguments(clientID: String, sessionID: String) -> [String] {
        ["--autostart=false", "-C", clientID, "do", "session.select", "--args", json(["session_id": sessionID])]
    }

    private static func json(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Client selection

    /// `{"clients":[…]}`; `clients` may be null and entries may have null `info`.
    static func parseClients(_ stdout: Data) -> [RexClient] {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let clients = object["clients"] as? [[String: Any]] else { return [] }
        return clients.compactMap { entry in
            guard let id = entry["client_id"] as? String, !id.isEmpty else { return nil }
            let info = entry["info"] as? [String: Any]
            return RexClient(
                id: id,
                kind: info?["kind"] as? String,
                platform: info?["platform"] as? String,
                label: info?["label"] as? String,
                connectionState: entry["connection_state"] as? String
            )
        }
    }

    /// Connected macOS app clients; the one labeled with this Mac's name wins, else the only
    /// one, else none. The API documents a missing or unknown `connection_state` as connected,
    /// so only `lost` is excluded.
    static func selectClient(_ clients: [RexClient], hostName: String?) -> RexClient? {
        let candidates = clients.filter {
            $0.kind == "app" && $0.platform == "macos" && $0.connectionState != "lost"
        }
        if let hostName, let match = candidates.first(where: { $0.label == hostName }) { return match }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: Result mapping

    /// nil on success. Cancellation is handled by the caller.
    static func focusError(_ result: ProcessResult, sessionName: String) -> FocusError? {
        switch result.outcome {
        case .exited(0):
            guard let reply = focusReply(result.stdout) else {
                return .failed(result.lastStderrLine ?? "Could not focus the pane in \(sessionName)")
            }
            if reply.ok { return nil }
            let message = reply.error ?? "unknown error"
            if message.contains(notFoundMarker) { return .failed(paneGone(sessionName)) }
            return .failed("\(sessionName): \(message)")
        case .exited(3):
            return .failed(sessionGone(sessionName))
        case .exited(4):
            return .unavailable(rexNotRunning)
        case .timedOut:
            return .failed(timedOut)
        case .exited, .signaled, .launchFailed, .cancelled:
            return .failed(result.lastStderrLine ?? "Could not focus the pane in \(sessionName)")
        }
    }

    /// The last stdout line that is a JSON object with a `focus` field.
    private static func focusReply(_ stdout: Data) -> (ok: Bool, error: String?)? {
        for line in String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let focus = object["focus"] as? String else { continue }
            return (focus == "ok", object["err"] as? String)
        }
        return nil
    }

    /// nil when the client switched; otherwise the partial-focus message.
    static func selectPartial(_ result: ProcessResult, sessionName: String) -> String? {
        switch result.outcome {
        case .exited(0):
            return nil
        case .exited(1) where result.stderrTail.contains(remoteControlOffMarker):
            return remoteControlOff
        case .exited(3):
            return appDisconnected
        case .timedOut:
            return timedOut + "."
        case .exited, .signaled, .launchFailed, .cancelled:
            return result.lastStderrLine ?? "Rex could not switch to \(sessionName)."
        }
    }
}

extension RexBackend {
    func focusServer(_ target: AgentTarget) async throws {
        try Task.checkCancellation()
        guard let cli = resolvedCLI else { throw FocusError.unavailable(RexFocus.rexNotRunning) }
        let name = sessionName(target.session.rawID)
        let result = await runner.run(ProcessRequest(
            executable: cli.path,
            arguments: RexFocus.focusArguments(sessionID: target.session.rawID, blockID: target.paneID),
            timeout: RexTimeouts.focus
        ))
        if result.outcome == .cancelled || Task.isCancelled { throw CancellationError() }
        if let error = RexFocus.focusError(result, sessionName: name) { throw error }
    }

    func activate(_ target: AgentTarget) async -> String? {
        let name = sessionName(target.session.rawID)
        let client = await selectedClient()
        // A superseded selection must not switch the client or bring Rex.app forward.
        if Task.isCancelled { return nil }

        guard let client, let cli = resolvedCLI else {
            guard await app.isRunning() else { return RexFocus.noClientRexNotRunning }
            if Task.isCancelled { return nil }
            await app.activate()
            return RexFocus.noClientRexRunning
        }

        let result = await runner.run(ProcessRequest(
            executable: cli.path,
            arguments: RexFocus.selectArguments(clientID: client.id, sessionID: target.session.rawID),
            timeout: RexTimeouts.focus
        ))
        if result.outcome == .cancelled || Task.isCancelled { return nil }
        let partial = RexFocus.selectPartial(result, sessionName: name)
        if Task.isCancelled { return nil }
        await app.activate()
        return partial
    }

    /// `client ls --json`, run fresh for each focus. Any failure means no client.
    private func selectedClient() async -> RexClient? {
        guard let cli = resolvedCLI else { return nil }
        let result = await runner.run(ProcessRequest(
            executable: cli.path,
            arguments: RexFocus.clientListArguments,
            timeout: RexTimeouts.clientList
        ))
        guard result.exitCode == 0 else { return nil }
        return RexFocus.selectClient(RexFocus.parseClients(result.stdout), hostName: hostName())
    }
}
