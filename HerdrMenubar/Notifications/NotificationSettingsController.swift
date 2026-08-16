import Foundation
import Observation
import OSLog

enum NotificationSettingsOperationError: Error, Equatable {
    case busy
}

@Observable @MainActor
final class NotificationSettingsController {
    private let service: any NativeNotificationServing
    private let preferences: Preferences
    private var activePermissionOperation: UUID?
    private var refreshGeneration: UInt = 0

    private(set) var systemSettings: NotificationSystemSettings = .notDetermined
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    var isEnabled: Bool { preferences.notificationsEnabled }
    var isSoundEnabled: Bool { preferences.notificationSoundEnabled }
    var canEnableSound: Bool { preferences.notificationsEnabled && !isChanging }

    var helpText: String? {
        if notificationsBlockedBySystem {
            return preferences.notificationsEnabled
                ? "Notifications are disabled in System Settings"
                : "Allow notifications in System Settings"
        }
        if preferences.notificationSoundEnabled && !systemSettings.soundsEnabled {
            return "Notification sounds are disabled in System Settings"
        }
        return nil
    }

    init(service: any NativeNotificationServing, preferences: Preferences) {
        self.service = service
        self.preferences = preferences
    }

    func refreshStatus() async {
        guard activePermissionOperation == nil else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let settings = await service.settings()
        guard activePermissionOperation == nil, refreshGeneration == generation else { return }
        systemSettings = settings
    }

    func setNotificationsEnabled(_ enabled: Bool) async throws {
        guard activePermissionOperation == nil else {
            throw NotificationSettingsOperationError.busy
        }
        if !enabled {
            refreshGeneration &+= 1
            preferences.notificationsEnabled = false
            errorMessage = nil
            return
        }

        let operationID = UUID()
        activePermissionOperation = operationID
        refreshGeneration &+= 1
        isChanging = true
        errorMessage = nil
        defer {
            if activePermissionOperation == operationID {
                activePermissionOperation = nil
                isChanging = false
            }
        }

        do {
            let granted = try await service.requestAuthorization()
            guard activePermissionOperation == operationID else { return }
            let settings = await service.settings()
            guard activePermissionOperation == operationID else { return }
            systemSettings = settings
            preferences.notificationsEnabled = granted
                && settings.authorization == .authorized
        } catch {
            guard activePermissionOperation == operationID else { throw error }
            preferences.notificationsEnabled = false
            errorMessage = "Could not enable notifications."
            AppLog.systemActions.error("Notification authorization failed")
            throw error
        }
    }

    func setSoundEnabled(_ enabled: Bool) {
        preferences.notificationSoundEnabled = enabled
    }

    private var notificationsBlockedBySystem: Bool {
        systemSettings.authorization == .denied
            || (systemSettings.authorization == .authorized && !systemSettings.alertsEnabled)
    }
}
