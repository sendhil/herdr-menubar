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

    func testLoginStatusMapsEverySystemState() {
        XCTAssertEqual(LoginItemService(backend: FakeLoginBackend(status: .enabled)).status, .enabled)
        XCTAssertEqual(LoginItemService(backend: FakeLoginBackend(status: .requiresApproval)).status, .requiresApproval)
        XCTAssertEqual(LoginItemService(backend: FakeLoginBackend(status: .notRegistered)).status, .disabled)
        XCTAssertEqual(LoginItemService(backend: FakeLoginBackend(status: .notFound)).status, .unavailable)
    }

    func testRefreshLoginStatusReflectsExternallyMutatedBackend() {
        let backend = FakeLoginBackend(status: .notRegistered)
        let service = LoginItemService(backend: backend)

        backend.setStatus(.requiresApproval)
        service.refreshStatus()

        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.helpText, "Allow in System Settings")
    }

    func testLoginRegistrationAndUnregistrationUseSystemConfirmedStatus() async throws {
        let backend = FakeLoginBackend(status: .notRegistered)
        let service = LoginItemService(backend: backend)

        try await service.setEnabled(true)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(backend.registerCount, 1)

        try await service.setEnabled(false)
        XCTAssertEqual(service.status, .disabled)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(backend.unregisterCount, 1)
    }

    func testLoginRegistrationFailurePreservesConfirmedDisabledState() async {
        let backend = FakeLoginBackend(status: .notRegistered, registerError: LoginTestFailure.failed)
        let service = LoginItemService(backend: backend)

        await XCTAssertThrowsErrorAsync(try await service.setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginTestFailure, .failed)
        }

        XCTAssertEqual(service.status, .disabled)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isChanging)
        XCTAssertEqual(service.errorMessage, "Could not update Launch at Login.")
    }

    func testLoginUnregistrationFailurePreservesConfirmedEnabledState() async {
        let backend = FakeLoginBackend(status: .enabled, unregisterError: LoginTestFailure.failed)
        let service = LoginItemService(backend: backend)

        await XCTAssertThrowsErrorAsync(try await service.setEnabled(false)) { error in
            XCTAssertEqual(error as? LoginTestFailure, .failed)
        }

        XCTAssertEqual(service.status, .enabled)
        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.isChanging)
    }

    func testConcurrentLoginUpdateThrowsBusyWithoutPerformingSecondOperation() async throws {
        let backend = FakeLoginBackend(status: .notRegistered)
        let service = LoginItemService(backend: backend)
        let firstOperation = Task { try await service.setEnabled(true) }
        while !service.isChanging { await Task.yield() }

        await XCTAssertThrowsErrorAsync(try await service.setEnabled(false)) { error in
            XCTAssertEqual(error as? LoginItemOperationError, .busy)
        }
        try await firstOperation.value

        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(backend.unregisterCount, 0)
        XCTAssertEqual(service.status, .enabled)
    }

    func testLaunchIntentPersistsOnlyAfterCompletedLoginOperation() async throws {
        let suiteName = "dev.herdr.menubar.login-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)
        let backend = FakeLoginBackend(status: .notRegistered)
        let service = LoginItemService(backend: backend)
        let firstOperation = Task {
            try await StatusMenu.updateLoginIntent(
                enabled: true,
                service: service,
                preferences: preferences
            )
        }
        while !service.isChanging { await Task.yield() }

        await XCTAssertThrowsErrorAsync(
            try await StatusMenu.updateLoginIntent(
                enabled: false,
                service: service,
                preferences: preferences
            )
        ) { error in
            XCTAssertEqual(error as? LoginItemOperationError, .busy)
        }
        XCTAssertFalse(preferences.launchAtLoginIntent)

        try await firstOperation.value
        XCTAssertTrue(preferences.launchAtLoginIntent)
        XCTAssertTrue(defaults.bool(forKey: Preferences.launchAtLoginIntentKey))
    }

    func testLoginErrorClearsAfterBoundedDisplayDuration() async {
        let backend = FakeLoginBackend(status: .notRegistered, registerError: LoginTestFailure.failed)
        let service = LoginItemService(backend: backend, errorDisplayDuration: .milliseconds(10))

        await XCTAssertThrowsErrorAsync(try await service.setEnabled(true)) { _ in }
        XCTAssertEqual(service.errorMessage, "Could not update Launch at Login.")

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(service.errorMessage)
    }

    func testRequiresApprovalIsNotEnabledAndProvidesSystemSettingsHelp() async throws {
        let backend = FakeLoginBackend(status: .notRegistered, statusAfterRegister: .requiresApproval)
        let service = LoginItemService(backend: backend)

        try await service.setEnabled(true)

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertEqual(service.helpText, "Allow in System Settings")
    }
}

private enum OpenFailure: Error {
    case refused
}

private enum LoginTestFailure: Error, Equatable {
    case failed
}

@MainActor
private final class FakeLoginBackend: LoginItemBackend {
    private(set) var status: LoginItemRegistrationStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let registerError: (any Error)?
    private let unregisterError: (any Error)?
    private let statusAfterRegister: LoginItemRegistrationStatus

    init(
        status: LoginItemRegistrationStatus,
        registerError: (any Error)? = nil,
        unregisterError: (any Error)? = nil,
        statusAfterRegister: LoginItemRegistrationStatus = .enabled
    ) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.statusAfterRegister = statusAfterRegister
    }

    func setStatus(_ status: LoginItemRegistrationStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
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
