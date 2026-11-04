import Foundation
import Observation

@Observable @MainActor
final class Preferences {
    static let defaultTerminalBundleIdentifier = "com.mitchellh.ghostty"
    static let selectedTerminalKey = "selectedTerminalBundleIdentifier"
    static let ghosttyDefaultMigrationKey = "ghosttyDefaultMigrationApplied"
    static let launchAtLoginIntentKey = "launchAtLoginIntent"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let notificationSoundEnabledKey = "notificationSoundEnabled"

    private let defaults: UserDefaults
    private static let hostedTestDefaults: UserDefaults = {
        let suiteName = "dev.herdr.menubar.hosted-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated hosted-test preferences")
        }
        return defaults
    }()

    static func applicationDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        guard environment["XCTestConfigurationFilePath"] != nil else { return .standard }
        return hostedTestDefaults
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

    init(defaults: UserDefaults = Preferences.applicationDefaults()) {
        self.defaults = defaults
        if !defaults.bool(forKey: Self.ghosttyDefaultMigrationKey) {
            if defaults.string(forKey: Self.selectedTerminalKey) == "com.github.wez.wezterm" {
                defaults.set(Self.defaultTerminalBundleIdentifier, forKey: Self.selectedTerminalKey)
            }
            defaults.set(true, forKey: Self.ghosttyDefaultMigrationKey)
        }
        selectedTerminalBundleIdentifier = defaults.string(forKey: Self.selectedTerminalKey)
            ?? Self.defaultTerminalBundleIdentifier
        launchAtLoginIntent = defaults.bool(forKey: Self.launchAtLoginIntentKey)
        notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
        notificationSoundEnabled = defaults.bool(forKey: Self.notificationSoundEnabledKey)
    }
}
