import AppKit
import Foundation

struct TerminalApp: Identifiable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String

    var id: String { bundleIdentifier }
}

@MainActor
struct TerminalCatalog {
    static let knownTerminals = [
        TerminalApp(name: "WezTerm", bundleIdentifier: "com.github.wez.wezterm"),
        TerminalApp(name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
        TerminalApp(name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
        TerminalApp(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
        TerminalApp(name: "Kitty", bundleIdentifier: "net.kovidgoyal.kitty"),
        TerminalApp(name: "Alacritty", bundleIdentifier: "org.alacritty")
    ]

    private let bundleURL: (String) -> URL?

    init(bundleURL: @escaping (String) -> URL? = { identifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }) {
        self.bundleURL = bundleURL
    }

    func installedTerminals() -> [TerminalApp] {
        Self.knownTerminals.filter { bundleURL($0.bundleIdentifier) != nil }
    }

    func terminal(bundleIdentifier: String) -> TerminalApp? {
        Self.knownTerminals.first { $0.bundleIdentifier == bundleIdentifier }
    }
}

enum TerminalActivationError: LocalizedError, Equatable {
    case applicationNotFound
    case activationRefused

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return "Selected terminal is not installed. Choose another terminal."
        case .activationRefused:
            return "Could not open the selected terminal."
        }
    }
}

@MainActor
protocol TerminalActivating {
    func activate(bundleIdentifier: String) async throws
}

@MainActor
struct TerminalActivationService: TerminalActivating {
    typealias OpenApplication = (URL, NSWorkspace.OpenConfiguration) async throws -> Void

    private let bundleURL: (String) -> URL?
    private let openApplication: OpenApplication

    init(
        bundleURL: @escaping (String) -> URL? = { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        },
        openApplication: @escaping OpenApplication = { appURL, configuration in
            _ = try await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
        }
    ) {
        self.bundleURL = bundleURL
        self.openApplication = openApplication
    }

    func activate(bundleIdentifier: String) async throws {
        guard let appURL = bundleURL(bundleIdentifier) else {
            throw TerminalActivationError.applicationNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            try await openApplication(appURL, configuration)
        } catch {
            throw TerminalActivationError.activationRefused
        }
    }
}
