import Foundation
import Observation

@Observable @MainActor
final class Preferences {
    static let defaultTerminalBundleIdentifier = "com.github.wez.wezterm"
    static let selectedTerminalKey = "selectedTerminalBundleIdentifier"

    private let defaults: UserDefaults

    var selectedTerminalBundleIdentifier: String {
        didSet {
            defaults.set(selectedTerminalBundleIdentifier, forKey: Self.selectedTerminalKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTerminalBundleIdentifier = defaults.string(forKey: Self.selectedTerminalKey)
            ?? Self.defaultTerminalBundleIdentifier
    }
}
