import Foundation
import Observation

@Observable @MainActor
final class Preferences {
    static let defaultTerminalBundleIdentifier = "com.github.wez.wezterm"
    static let selectedTerminalKey = "selectedTerminalBundleIdentifier"
    static let launchAtLoginIntentKey = "launchAtLoginIntent"

    private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTerminalBundleIdentifier = defaults.string(forKey: Self.selectedTerminalKey)
            ?? Self.defaultTerminalBundleIdentifier
        launchAtLoginIntent = defaults.bool(forKey: Self.launchAtLoginIntentKey)
    }
}
