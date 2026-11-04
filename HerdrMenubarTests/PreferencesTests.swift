import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class PreferencesTests: XCTestCase {
    func testHostedTestsUseIsolatedDefaultDomain() {
        let defaults = Preferences.applicationDefaults(
            environment: ["XCTestConfigurationFilePath": "/test-only/configuration.xctest"]
        )
        XCTAssertFalse(defaults === UserDefaults.standard, "Hosted tests must never use saved application preferences")
    }

    func testImplicitDefaultFactoryRecognizesTheHostedProcess() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        XCTAssertFalse(Preferences.applicationDefaults() === UserDefaults.standard)
    }

    func testNormalLaunchUsesStandardDefaultDomain() {
        XCTAssertTrue(Preferences.applicationDefaults(environment: [:]) === UserDefaults.standard)
    }

    func testTerminalDefaultsToGhostty() {
        withDefaults { defaults in
            XCTAssertEqual(
                Preferences(defaults: defaults).selectedTerminalBundleIdentifier,
                "com.mitchellh.ghostty"
            )
            XCTAssertTrue(defaults.bool(forKey: "ghosttyDefaultMigrationApplied"))
        }
    }

    func testSelectedTerminalPersistsInInjectedDefaults() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.selectedTerminalBundleIdentifier = "com.apple.Terminal"

            XCTAssertEqual(
                Preferences(defaults: defaults).selectedTerminalBundleIdentifier,
                "com.apple.Terminal"
            )
            XCTAssertEqual(
                defaults.string(forKey: "selectedTerminalBundleIdentifier"),
                "com.apple.Terminal"
            )
        }
    }

    func testSavedWezTermMigratesToGhosttyWithoutChangingOtherSettings() {
        withDefaults { defaults in
            defaults.set("com.github.wez.wezterm", forKey: Preferences.selectedTerminalKey)
            defaults.set(true, forKey: Preferences.launchAtLoginIntentKey)
            defaults.set(true, forKey: Preferences.notificationsEnabledKey)
            defaults.set(true, forKey: Preferences.notificationSoundEnabledKey)

            let preferences = Preferences(defaults: defaults)

            XCTAssertEqual(preferences.selectedTerminalBundleIdentifier, "com.mitchellh.ghostty")
            XCTAssertEqual(defaults.string(forKey: Preferences.selectedTerminalKey), "com.mitchellh.ghostty")
            XCTAssertTrue(defaults.bool(forKey: "ghosttyDefaultMigrationApplied"))
            XCTAssertTrue(preferences.launchAtLoginIntent)
            XCTAssertTrue(preferences.notificationsEnabled)
            XCTAssertTrue(preferences.notificationSoundEnabled)
        }
    }

    func testExplicitWezTermSelectionAfterMigrationIsNotMigratedAgain() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.selectedTerminalBundleIdentifier = "com.github.wez.wezterm"

            XCTAssertEqual(Preferences(defaults: defaults).selectedTerminalBundleIdentifier, "com.github.wez.wezterm")
            XCTAssertEqual(defaults.string(forKey: Preferences.selectedTerminalKey), "com.github.wez.wezterm")
            XCTAssertTrue(defaults.bool(forKey: "ghosttyDefaultMigrationApplied"))
        }
    }

    func testCompletedMigrationPreservesEveryExplicitTerminalChoice() {
        for bundleIdentifier in ["com.github.wez.wezterm", "com.mitchellh.ghostty", "com.apple.Terminal"] {
            withDefaults { defaults in
                defaults.set(true, forKey: "ghosttyDefaultMigrationApplied")
                defaults.set(bundleIdentifier, forKey: Preferences.selectedTerminalKey)

                XCTAssertEqual(Preferences(defaults: defaults).selectedTerminalBundleIdentifier, bundleIdentifier)
                XCTAssertEqual(defaults.string(forKey: Preferences.selectedTerminalKey), bundleIdentifier)
            }
        }
    }

    func testLaunchAtLoginIntentDefaultsOff() {
        withDefaults { defaults in
            XCTAssertFalse(Preferences(defaults: defaults).launchAtLoginIntent)
        }
    }

    func testLaunchAtLoginIntentPersistsInInjectedDefaults() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.launchAtLoginIntent = true

            XCTAssertTrue(Preferences(defaults: defaults).launchAtLoginIntent)
            XCTAssertTrue(defaults.bool(forKey: "launchAtLoginIntent"))
        }
    }

    func testNotificationPreferencesDefaultOff() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            XCTAssertFalse(preferences.notificationsEnabled)
            XCTAssertFalse(preferences.notificationSoundEnabled)
        }
    }

    func testNotificationPreferencesPersistIndependently() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.notificationsEnabled = true
            preferences.notificationSoundEnabled = true

            let restored = Preferences(defaults: defaults)
            XCTAssertTrue(restored.notificationsEnabled)
            XCTAssertTrue(restored.notificationSoundEnabled)
            XCTAssertTrue(defaults.bool(forKey: Preferences.notificationsEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: Preferences.notificationSoundEnabledKey))

            restored.notificationsEnabled = false
            XCTAssertFalse(Preferences(defaults: defaults).notificationsEnabled)
            XCTAssertTrue(Preferences(defaults: defaults).notificationSoundEnabled)
        }
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) -> Void) {
        let suiteName = "dev.herdr.menubar.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated user defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        body(defaults)
    }
}
