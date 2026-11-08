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
    static let enabledBackendsKey = "enabledBackends"
    static let defaultEnabledBackends: Set<BackendKind> = [.herdr]
    static let rexCLIPathKey = "rexCLIPath"

    static func notifyStatesKey(for kind: BackendKind) -> String {
        "notifyStates.\(kind.rawValue)"
    }

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

    /// Read once at launch. Changed only with `defaults write`; there is no UI.
    let enabledBackends: Set<BackendKind>

    /// Read once at launch. Changed only with `defaults write`; nil (absent or blank) means
    /// resolve the Rex CLI automatically.
    let rexCLIPath: String?

    /// One entry per backend. Absent keys use `BackendKind.defaultNotifyStates` and are not written.
    private(set) var notifyStates: [BackendKind: Set<AttentionState>]

    func setNotifyStates(_ states: Set<AttentionState>, for kind: BackendKind) {
        notifyStates[kind] = states
        defaults.set(states.map(\.rawValue).sorted(), forKey: Self.notifyStatesKey(for: kind))
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
        enabledBackends = defaults.stringArray(forKey: Self.enabledBackendsKey)
            .map { Set($0.compactMap(BackendKind.init(rawValue:))) }
            ?? Self.defaultEnabledBackends
        rexCLIPath = defaults.string(forKey: Self.rexCLIPathKey)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        notifyStates = Dictionary(uniqueKeysWithValues: BackendKind.allCases.map { kind in
            let stored = defaults.stringArray(forKey: Self.notifyStatesKey(for: kind))
                .map { Set($0.compactMap(AttentionState.init(rawValue:))) }
            return (kind, stored ?? kind.defaultNotifyStates)
        })
    }
}
