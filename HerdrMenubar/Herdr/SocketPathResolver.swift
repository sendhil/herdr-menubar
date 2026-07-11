import Foundation

protocol SocketPathResolving: Sendable {
    func resolve(environment: [String: String], homeDirectory: URL) -> URL
}

extension SocketPathResolving {
    func resolve() -> URL {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}

struct SocketPathResolver: SocketPathResolving {
    func resolve(environment: [String: String], homeDirectory: URL) -> URL {
        if let override = environment["HERDR_SOCKET_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let root = homeDirectory.appending(path: ".config/herdr", directoryHint: .isDirectory)
        if let session = environment["HERDR_SESSION"], !session.isEmpty {
            return root.appending(path: "sessions/\(session)/herdr.sock")
        }
        return root.appending(path: "herdr.sock")
    }
}
