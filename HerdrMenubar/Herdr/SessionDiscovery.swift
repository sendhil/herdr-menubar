import Foundation

enum SessionID: Hashable, Sendable {
    case `default`
    case named(String)

    var displayName: String {
        switch self {
        case .default: "Default"
        case .named(let name): name
        }
    }
}

struct SessionDescriptor: Identifiable, Equatable, Sendable {
    let id: SessionID
    let socketURL: URL
    var displayName: String { id.displayName }
}

protocol SessionDiscovering: Sendable {
    func discover() async throws -> [SessionDescriptor]
}

struct SessionDiscovery: SessionDiscovering, @unchecked Sendable {
    let configRoot: URL
    private let fileManager: FileManager

    init(configRoot: URL, fileManager: FileManager = .default) {
        self.configRoot = configRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.init(
            configRoot: Self.configurationRoot(environment: environment, homeDirectory: homeDirectory),
            fileManager: fileManager
        )
    }

    static func configurationRoot(environment: [String: String], homeDirectory: URL) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        return base.appending(path: "herdr", directoryHint: .isDirectory).standardizedFileURL
    }

    func discover() async throws -> [SessionDescriptor] {
        var result: [SessionDescriptor] = []
        let defaultSocket = configRoot.appending(path: "herdr.sock")
        if try fileType(at: defaultSocket) == .typeSocket {
            result.append(SessionDescriptor(id: .default, socketURL: defaultSocket))
        }

        let sessions = configRoot.appending(path: "sessions", directoryHint: .isDirectory)
        guard let sessionsType = try fileType(at: sessions) else { return result }
        guard sessionsType == .typeDirectory else { return result }
        let names = try fileManager.contentsOfDirectory(atPath: sessions.path)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .sorted {
                let lhs = $0.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let rhs = $1.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        for name in names {
            let directory = sessions.appending(path: name, directoryHint: .isDirectory)
            guard try fileType(at: directory) == .typeDirectory else { continue }
            let socket = directory.appending(path: "herdr.sock")
            guard try fileType(at: socket) == .typeSocket else { continue }
            result.append(SessionDescriptor(id: .named(name), socketURL: socket))
        }
        return result
    }

    private func fileType(at url: URL) throws -> FileAttributeType? {
        do {
            return try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}
