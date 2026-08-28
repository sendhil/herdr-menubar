import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class NotificationSettingsControllerTests: XCTestCase {
    func testDefaultsRemainOff() {
        let fixture = makeFixture()
        defer { fixture.removeDefaults() }

        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertFalse(fixture.controller.isSoundEnabled)
        XCTAssertFalse(fixture.controller.canEnableSound)
        XCTAssertNil(fixture.controller.errorMessage)
        XCTAssertNil(fixture.controller.helpText)
    }

    func testEnablePersistsAfterGrantedAuthorizedRequest() async throws {
        let fixture = makeFixture(authorizationResult: true, settings: .authorized)
        defer { fixture.removeDefaults() }

        try await fixture.controller.setNotificationsEnabled(true)

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertTrue(fixture.preferences.notificationsEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: Preferences.notificationsEnabledKey))
        XCTAssertEqual(fixture.controller.systemSettings, .authorized)
        let authorizationRequests = await fixture.service.authorizationRequests
        XCTAssertEqual(authorizationRequests, 1)
    }

    func testGrantedAuthorizedRequestPreservesIntentWhenSystemAlertsAreDisabled() async throws {
        let alertsDisabled = NotificationSystemSettings(
            authorization: .authorized,
            alertsEnabled: false,
            soundsEnabled: true
        )
        let fixture = makeFixture(authorizationResult: true, settings: alertsDisabled)
        defer { fixture.removeDefaults() }

        try await fixture.controller.setNotificationsEnabled(true)

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: Preferences.notificationsEnabledKey))
        XCTAssertEqual(
            fixture.controller.helpText,
            "Notifications are disabled in System Settings"
        )
    }

    func testDenialLeavesIntentOffAndShowsSystemSettingsHelp() async throws {
        let fixture = makeFixture(authorizationResult: false, settings: .denied)
        defer { fixture.removeDefaults() }

        try await fixture.controller.setNotificationsEnabled(true)

        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertFalse(fixture.preferences.notificationsEnabled)
        XCTAssertEqual(fixture.controller.helpText, "Allow notifications in System Settings")
        XCTAssertNil(fixture.controller.errorMessage)
    }

    func testAuthorizationErrorLeavesIntentOffAndRestoresChangingState() async {
        let fixture = makeFixture(
            authorizationResult: true,
            settings: .authorized,
            authorizationError: NotificationSettingsTestError.sensitive("private-system-detail")
        )
        defer { fixture.removeDefaults() }

        await XCTAssertThrowsErrorAsync(
            try await fixture.controller.setNotificationsEnabled(true)
        ) { error in
            XCTAssertEqual(
                error as? NotificationSettingsTestError,
                .sensitive("private-system-detail")
            )
        }

        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertFalse(fixture.controller.isChanging)
        XCTAssertEqual(fixture.controller.errorMessage, "Could not enable notifications.")
        XCTAssertFalse(fixture.controller.errorMessage?.contains("private-system-detail") == true)
    }

    func testDisableDoesNotRequestAuthorizationOrEraseSoundPreference() async throws {
        let fixture = makeFixture()
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true
        fixture.preferences.notificationSoundEnabled = true

        try await fixture.controller.setNotificationsEnabled(false)

        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertTrue(fixture.controller.isSoundEnabled)
        XCTAssertFalse(fixture.controller.canEnableSound)
        let authorizationRequests = await fixture.service.authorizationRequests
        XCTAssertEqual(authorizationRequests, 0)
    }

    func testExternalRevocationPreservesIntentAndRefreshShowsHelp() async {
        let fixture = makeFixture(settings: .authorized)
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true
        await fixture.service.setSettings(.denied)

        await fixture.controller.refreshStatus()

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: Preferences.notificationsEnabledKey))
        XCTAssertEqual(
            fixture.controller.helpText,
            "Notifications are disabled in System Settings"
        )
    }

    func testRefreshAfterSystemReauthorizationClearsHelpWithoutRewritingIntent() async {
        let fixture = makeFixture(settings: .denied)
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true

        await fixture.controller.refreshStatus()
        XCTAssertEqual(
            fixture.controller.helpText,
            "Notifications are disabled in System Settings"
        )

        await fixture.service.setSettings(.authorized)
        await fixture.controller.refreshStatus()

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: Preferences.notificationsEnabledKey))
        XCTAssertNil(fixture.controller.helpText)
    }

    func testApplicationActivationRefreshesSettingsWithoutRequestingOrRewritingIntent() async {
        let fixture = makeFixture(settings: .authorized)
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true
        fixture.preferences.notificationSoundEnabled = true
        let appDelegate = HerdrAppDelegate()
        appDelegate.notificationSettings = fixture.controller

        appDelegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification)
        )
        await fixture.service.waitForSettingsRequests(1)

        XCTAssertEqual(fixture.controller.systemSettings, .authorized)
        XCTAssertTrue(fixture.preferences.notificationsEnabled)
        XCTAssertTrue(fixture.preferences.notificationSoundEnabled)
        let authorizationRequests = await fixture.service.authorizationRequests
        XCTAssertEqual(authorizationRequests, 0)
    }

    func testSoundPersistsIndependentlyAndRequiresNotificationsOnAndIdle() async throws {
        let fixture = makeFixture(settings: .authorized, gateAuthorization: true)
        defer { fixture.removeDefaults() }

        fixture.controller.setSoundEnabled(true)
        XCTAssertTrue(fixture.controller.isSoundEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: Preferences.notificationSoundEnabledKey))
        XCTAssertFalse(fixture.controller.canEnableSound)

        fixture.preferences.notificationsEnabled = true
        XCTAssertTrue(fixture.controller.canEnableSound)

        let operation = Task { try await fixture.controller.setNotificationsEnabled(true) }
        await fixture.service.waitForAuthorizationRequests(1)
        XCTAssertTrue(fixture.controller.isChanging)
        XCTAssertFalse(fixture.controller.canEnableSound)

        await fixture.service.releaseAuthorization()
        try await operation.value
        XCTAssertTrue(fixture.controller.canEnableSound)
    }

    func testSystemSoundDisabledShowsHelp() async {
        let soundsDisabled = NotificationSystemSettings(
            authorization: .authorized,
            alertsEnabled: true,
            soundsEnabled: false
        )
        let fixture = makeFixture(settings: soundsDisabled)
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true
        fixture.preferences.notificationSoundEnabled = true

        await fixture.controller.refreshStatus()

        XCTAssertEqual(
            fixture.controller.helpText,
            "Notification sounds are disabled in System Settings"
        )
    }

    func testConcurrentPermissionOperationThrowsBusyAndRequestsAuthorizationOnce() async throws {
        let fixture = makeFixture(settings: .authorized, gateAuthorization: true)
        defer { fixture.removeDefaults() }
        let firstOperation = Task {
            try await fixture.controller.setNotificationsEnabled(true)
        }
        await fixture.service.waitForAuthorizationRequests(1)

        XCTAssertTrue(fixture.controller.isChanging)
        await XCTAssertThrowsErrorAsync(
            try await fixture.controller.setNotificationsEnabled(true)
        ) { error in
            XCTAssertEqual(error as? NotificationSettingsOperationError, .busy)
        }
        var authorizationRequests = await fixture.service.authorizationRequests
        XCTAssertEqual(authorizationRequests, 1)

        await fixture.service.releaseAuthorization()
        try await firstOperation.value

        XCTAssertFalse(fixture.controller.isChanging)
        authorizationRequests = await fixture.service.authorizationRequests
        XCTAssertEqual(authorizationRequests, 1)
    }

    func testOlderGatedRefreshCannotOverwriteNewerRefresh() async {
        let fixture = makeFixture(settings: .denied, gateNextSettings: true)
        defer { fixture.removeDefaults() }
        let olderRefresh = Task { await fixture.controller.refreshStatus() }
        await fixture.service.waitForSettingsRequests(1)

        await fixture.service.setSettings(.authorized)
        await fixture.controller.refreshStatus()
        XCTAssertEqual(fixture.controller.systemSettings, .authorized)

        await fixture.service.releaseSettings()
        await olderRefresh.value

        XCTAssertEqual(fixture.controller.systemSettings, .authorized)
    }

    func testOlderGatedRefreshCannotOverwriteNewerPermissionOperation() async throws {
        let fixture = makeFixture(settings: .denied, gateNextSettings: true)
        defer { fixture.removeDefaults() }
        let olderRefresh = Task { await fixture.controller.refreshStatus() }
        await fixture.service.waitForSettingsRequests(1)

        await fixture.service.setSettings(.authorized)
        try await fixture.controller.setNotificationsEnabled(true)
        XCTAssertEqual(fixture.controller.systemSettings, .authorized)
        XCTAssertTrue(fixture.controller.isEnabled)

        await fixture.service.releaseSettings()
        await olderRefresh.value

        XCTAssertEqual(fixture.controller.systemSettings, .authorized)
        XCTAssertTrue(fixture.controller.isEnabled)
        let settingsRequests = await fixture.service.settingsRequests
        XCTAssertEqual(settingsRequests, 2)
    }

    func testRefreshDuringGatedPermissionOperationDoesNotReadOrMutateSettings() async throws {
        let fixture = makeFixture(settings: .authorized, gateAuthorization: true)
        defer { fixture.removeDefaults() }
        let permissionOperation = Task {
            try await fixture.controller.setNotificationsEnabled(true)
        }
        await fixture.service.waitForAuthorizationRequests(1)

        await fixture.controller.refreshStatus()

        var settingsRequests = await fixture.service.settingsRequests
        XCTAssertEqual(settingsRequests, 0)
        XCTAssertEqual(fixture.controller.systemSettings, .notDetermined)
        XCTAssertFalse(fixture.controller.isEnabled)

        await fixture.service.releaseAuthorization()
        try await permissionOperation.value

        settingsRequests = await fixture.service.settingsRequests
        XCTAssertEqual(settingsRequests, 1)
        XCTAssertEqual(fixture.controller.systemSettings, .authorized)
        XCTAssertTrue(fixture.controller.isEnabled)
    }

    func testCancellationDuringAuthorizationPreservesControllerState() async {
        let fixture = makeFixture(
            settings: .denied,
            authorizationError: .sensitive("preexisting-error")
        )
        defer { fixture.removeDefaults() }

        await XCTAssertThrowsErrorAsync(
            try await fixture.controller.setNotificationsEnabled(true)
        ) { error in
            XCTAssertEqual(
                error as? NotificationSettingsTestError,
                .sensitive("preexisting-error")
            )
        }
        fixture.preferences.notificationsEnabled = true
        await fixture.controller.refreshStatus()
        await fixture.service.setAuthorizationError(nil)
        await fixture.service.setSettings(.authorized)
        await fixture.service.gateNextAuthorization()
        let initialState = controllerState(fixture)
        XCTAssertEqual(initialState.errorMessage, "Could not enable notifications.")

        let operation = Task {
            try await fixture.controller.setNotificationsEnabled(true)
        }
        await fixture.service.waitForAuthorizationRequests(2)
        XCTAssertTrue(fixture.controller.isChanging)

        operation.cancel()
        await fixture.service.releaseAuthorization()
        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(fixture.controller.isChanging)
        XCTAssertEqual(controllerState(fixture), initialState)
    }

    func testCooperativeCancellationDuringAuthorizationPreservesControllerState() async {
        let fixture = makeFixture(settings: .denied)
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true
        await fixture.controller.refreshStatus()
        await fixture.service.setSettings(.authorized)
        await fixture.service.suspendNextAuthorizationUntilCancellation()
        let initialState = controllerState(fixture)

        let operation = Task {
            try await fixture.controller.setNotificationsEnabled(true)
        }
        await fixture.service.waitForAuthorizationRequests(1)
        XCTAssertTrue(fixture.controller.isChanging)

        operation.cancel()
        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(fixture.controller.isChanging)
        XCTAssertEqual(controllerState(fixture), initialState)
        let authorizationRequests = await fixture.service.authorizationRequests
        XCTAssertEqual(authorizationRequests, 1)
        XCTAssertNil(fixture.controller.errorMessage)
    }

    func testCancellationDuringPermissionSettingsReadPreservesControllerState() async {
        let fixture = makeFixture(settings: .denied)
        defer { fixture.removeDefaults() }
        fixture.preferences.notificationsEnabled = true
        await fixture.controller.refreshStatus()
        await fixture.service.setSettings(.authorized)
        await fixture.service.gateNextSettings()
        let initialState = controllerState(fixture)

        let operation = Task {
            try await fixture.controller.setNotificationsEnabled(true)
        }
        await fixture.service.waitForSettingsRequests(2)
        XCTAssertTrue(fixture.controller.isChanging)

        operation.cancel()
        await fixture.service.releaseSettings()
        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(fixture.controller.isChanging)
        XCTAssertEqual(controllerState(fixture), initialState)
    }

    func testCancellationDuringRefreshDiscardsSettingsResult() async {
        let fixture = makeFixture(settings: .denied)
        defer { fixture.removeDefaults() }
        await fixture.controller.refreshStatus()
        await fixture.service.setSettings(.authorized)
        await fixture.service.gateNextSettings()

        let refresh = Task { await fixture.controller.refreshStatus() }
        await fixture.service.waitForSettingsRequests(2)

        refresh.cancel()
        await fixture.service.releaseSettings()
        await refresh.value

        XCTAssertEqual(fixture.controller.systemSettings, .denied)
    }

    private func controllerState(
        _ fixture: NotificationSettingsFixture
    ) -> NotificationSettingsControllerState {
        NotificationSettingsControllerState(
            notificationsEnabled: fixture.controller.isEnabled,
            systemSettings: fixture.controller.systemSettings,
            errorMessage: fixture.controller.errorMessage
        )
    }

    private func makeFixture(
        authorizationResult: Bool = true,
        settings: NotificationSystemSettings = .notDetermined,
        authorizationError: NotificationSettingsTestError? = nil,
        gateAuthorization: Bool = false,
        gateNextSettings: Bool = false
    ) -> NotificationSettingsFixture {
        NotificationSettingsFixture(
            authorizationResult: authorizationResult,
            settings: settings,
            authorizationError: authorizationError,
            gateAuthorization: gateAuthorization,
            gateNextSettings: gateNextSettings
        )
    }
}

@MainActor
private final class NotificationSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let preferences: Preferences
    let service: FakeNotificationSettingsService
    let controller: NotificationSettingsController

    init(
        authorizationResult: Bool,
        settings: NotificationSystemSettings,
        authorizationError: NotificationSettingsTestError?,
        gateAuthorization: Bool,
        gateNextSettings: Bool
    ) {
        suiteName = "dev.herdr.menubar.notification-settings-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        preferences = Preferences(defaults: defaults)
        service = FakeNotificationSettingsService(
            authorizationResult: authorizationResult,
            settings: settings,
            authorizationError: authorizationError,
            gateAuthorization: gateAuthorization,
            gateNextSettings: gateNextSettings
        )
        controller = NotificationSettingsController(service: service, preferences: preferences)
    }

    func removeDefaults() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum NotificationSettingsTestError: Error, Equatable {
    case sensitive(String)
}

private struct NotificationSettingsControllerState: Equatable {
    let notificationsEnabled: Bool
    let systemSettings: NotificationSystemSettings
    let errorMessage: String?
}

private actor FakeNotificationSettingsService: NativeNotificationServing {
    private(set) var authorizationRequests = 0
    private(set) var settingsRequests = 0

    private var authorizationResult: Bool
    private var settingsValue: NotificationSystemSettings
    private var authorizationError: NotificationSettingsTestError?
    private var shouldGateAuthorization: Bool
    private var authorizationCancellationWatchdogNanoseconds: UInt64?
    private var shouldGateNextSettings: Bool
    private var authorizationGate: CheckedContinuation<Void, Never>?
    private var settingsGate: CheckedContinuation<Void, Never>?
    private var authorizationRequestWaiters: [RequestWaiter] = []
    private var settingsRequestWaiters: [RequestWaiter] = []

    init(
        authorizationResult: Bool,
        settings: NotificationSystemSettings,
        authorizationError: NotificationSettingsTestError?,
        gateAuthorization: Bool,
        gateNextSettings: Bool
    ) {
        self.authorizationResult = authorizationResult
        settingsValue = settings
        self.authorizationError = authorizationError
        shouldGateAuthorization = gateAuthorization
        shouldGateNextSettings = gateNextSettings
    }

    func responses() async -> NotificationResponseSubscription {
        .finished()
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        resumeSatisfiedWaiters(
            currentCount: authorizationRequests,
            waiters: &authorizationRequestWaiters
        )
        if shouldGateAuthorization {
            shouldGateAuthorization = false
            await withCheckedContinuation { authorizationGate = $0 }
        }
        if let watchdog = authorizationCancellationWatchdogNanoseconds {
            authorizationCancellationWatchdogNanoseconds = nil
            try await Task.sleep(nanoseconds: watchdog)
        }
        if let authorizationError { throw authorizationError }
        return authorizationResult
    }

    func settings() async -> NotificationSystemSettings {
        settingsRequests += 1
        let result = settingsValue
        resumeSatisfiedWaiters(currentCount: settingsRequests, waiters: &settingsRequestWaiters)
        if shouldGateNextSettings {
            shouldGateNextSettings = false
            await withCheckedContinuation { settingsGate = $0 }
        }
        return result
    }

    func deliver(
        _ event: AttentionNotificationEvent,
        sound: Bool
    ) async throws -> NotificationDeliveryResult {
        .accepted
    }

    func setSettings(_ settings: NotificationSystemSettings) {
        settingsValue = settings
    }

    func setAuthorizationError(_ error: NotificationSettingsTestError?) {
        authorizationError = error
    }

    func gateNextAuthorization() {
        shouldGateAuthorization = true
    }

    func suspendNextAuthorizationUntilCancellation() {
        authorizationCancellationWatchdogNanoseconds = 5_000_000_000
    }

    func gateNextSettings() {
        shouldGateNextSettings = true
    }

    func waitForAuthorizationRequests(_ count: Int) async {
        guard authorizationRequests < count else { return }
        await withCheckedContinuation { continuation in
            authorizationRequestWaiters.append(
                RequestWaiter(count: count, continuation: continuation)
            )
        }
    }

    func waitForSettingsRequests(_ count: Int) async {
        guard settingsRequests < count else { return }
        await withCheckedContinuation { continuation in
            settingsRequestWaiters.append(
                RequestWaiter(count: count, continuation: continuation)
            )
        }
    }

    func releaseAuthorization() {
        authorizationGate?.resume()
        authorizationGate = nil
    }

    func releaseSettings() {
        settingsGate?.resume()
        settingsGate = nil
    }

    private func resumeSatisfiedWaiters(
        currentCount: Int,
        waiters: inout [RequestWaiter]
    ) {
        let satisfied = waiters.filter { $0.count <= currentCount }
        waiters.removeAll { $0.count <= currentCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

private struct RequestWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
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
