import Foundation
import Observation

@Observable @MainActor
final class Preferences {
    static let defaultTerminalBundleIdentifier = "com.github.wez.wezterm"
    static let selectedTerminalKey = "selectedTerminalBundleIdentifier"
    static let launchAtLoginIntentKey = "launchAtLoginIntent"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let notificationSoundEnabledKey = "notificationSoundEnabled"
    static let widgetUpdatesEnabledKey = "widgetUpdatesEnabled"

    private let defaults: UserDefaults

    var widgetUpdatesEnabled: Bool {
        didSet { defaults.set(widgetUpdatesEnabled, forKey: Self.widgetUpdatesEnabledKey) }
    }

    var selectedTerminalBundleIdentifier: String {
        didSet {
            defaults.set(selectedTerminalBundleIdentifier, forKey: Self.selectedTerminalKey)
        }
    }

    var launchAtLoginIntent: Bool {
        didSet {
            defaults.set(launchAtLoginIntent, forKey: Self.launchAtLoginIntentKey)
        }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Self.notificationsEnabledKey) }
    }

    var notificationSoundEnabled: Bool {
        didSet { defaults.set(notificationSoundEnabled, forKey: Self.notificationSoundEnabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        widgetUpdatesEnabled = defaults.object(forKey: Self.widgetUpdatesEnabledKey) == nil
            || defaults.bool(forKey: Self.widgetUpdatesEnabledKey)
        selectedTerminalBundleIdentifier = defaults.string(forKey: Self.selectedTerminalKey)
            ?? Self.defaultTerminalBundleIdentifier
        launchAtLoginIntent = defaults.bool(forKey: Self.launchAtLoginIntentKey)
        notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
        notificationSoundEnabled = defaults.bool(forKey: Self.notificationSoundEnabledKey)
    }
}
