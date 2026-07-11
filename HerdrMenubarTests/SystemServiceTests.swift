import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class SystemServiceTests: XCTestCase {
    func testCatalogReturnsOnlyInstalledKnownTerminalsInPickerOrder() {
        let installed = [
            "com.github.wez.wezterm",
            "com.apple.Terminal",
            "org.alacritty"
        ]
        let catalog = TerminalCatalog(bundleURL: { identifier in
            installed.contains(identifier)
                ? URL(fileURLWithPath: "/Applications/\(identifier).app")
                : nil
        })

        XCTAssertEqual(
            catalog.installedTerminals().map(\.bundleIdentifier),
            installed
        )
    }

    func testCatalogContainsTheKnownTerminalIdentifiersInPickerOrder() {
        XCTAssertEqual(
            TerminalCatalog.knownTerminals.map(\.bundleIdentifier),
            [
                "com.github.wez.wezterm",
                "com.mitchellh.ghostty",
                "com.googlecode.iterm2",
                "com.apple.Terminal",
                "net.kovidgoyal.kitty",
                "org.alacritty"
            ]
        )
    }

    func testActivationOpensResolvedApplicationWithActivationEnabled() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/WezTerm.app")
        var openedURL: URL?
        var activates: Bool?
        let service = TerminalActivationService(
            bundleURL: { $0 == "com.github.wez.wezterm" ? appURL : nil },
            openApplication: { url, configuration in
                openedURL = url
                activates = configuration.activates
            }
        )

        try await service.activate(bundleIdentifier: "com.github.wez.wezterm")

        XCTAssertEqual(openedURL, appURL)
        XCTAssertEqual(activates, true)
    }

    func testMissingApplicationThrowsConciseTypedError() async {
        let service = TerminalActivationService(
            bundleURL: { _ in nil },
            openApplication: { _, _ in XCTFail("must not open") }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.activate(bundleIdentifier: "missing.terminal")
        ) { error in
            XCTAssertEqual(error as? TerminalActivationError, .applicationNotFound)
            XCTAssertEqual(error.localizedDescription, "Selected terminal is not installed. Choose another terminal.")
        }
    }

    func testOpenFailureThrowsConciseTypedError() async {
        let service = TerminalActivationService(
            bundleURL: { _ in URL(fileURLWithPath: "/Applications/WezTerm.app") },
            openApplication: { _, _ in throw OpenFailure.refused }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.activate(bundleIdentifier: "com.github.wez.wezterm")
        ) { error in
            XCTAssertEqual(error as? TerminalActivationError, .activationRefused)
            XCTAssertEqual(error.localizedDescription, "Could not open the selected terminal.")
        }
    }
}

private enum OpenFailure: Error {
    case refused
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ handler: (any Error) -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected error")
    } catch {
        handler(error)
    }
}
