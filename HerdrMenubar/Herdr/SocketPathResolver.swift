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

        let configDirectory: URL
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            configDirectory = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
        } else {
            configDirectory = homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        }
        let root = configDirectory.appending(path: "herdr", directoryHint: .isDirectory)
        if let session = environment["HERDR_SESSION"], !session.isEmpty, session != "default" {
            return root.appending(path: "sessions/\(session)/herdr.sock")
        }
        return root.appending(path: "herdr.sock")
    }
}
