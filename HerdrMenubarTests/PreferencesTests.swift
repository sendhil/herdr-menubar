import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class PreferencesTests: XCTestCase {
    func testTerminalDefaultsToWezTerm() {
        withDefaults { defaults in
            XCTAssertEqual(
                Preferences(defaults: defaults).selectedTerminalBundleIdentifier,
                "com.github.wez.wezterm"
            )
        }
    }

    func testSelectedTerminalPersistsInInjectedDefaults() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.selectedTerminalBundleIdentifier = "com.mitchellh.ghostty"

            XCTAssertEqual(
                Preferences(defaults: defaults).selectedTerminalBundleIdentifier,
                "com.mitchellh.ghostty"
            )
            XCTAssertEqual(
                defaults.string(forKey: "selectedTerminalBundleIdentifier"),
                "com.mitchellh.ghostty"
            )
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

    func testWidgetUpdatesDefaultToAutomaticWithoutChangingOtherPreferences() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            XCTAssertTrue(preferences.widgetUpdatesEnabled)
            XCTAssertFalse(preferences.notificationsEnabled)
            XCTAssertFalse(preferences.launchAtLoginIntent)
            XCTAssertNil(defaults.object(forKey: "widgetUpdatesEnabled"))
        }
    }

    func testWidgetUpdatesOffPersistsAcrossRestartsIndependently() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.notificationsEnabled = true
            preferences.selectedTerminalBundleIdentifier = "com.mitchellh.ghostty"
            preferences.widgetUpdatesEnabled = false

            let restored = Preferences(defaults: defaults)
            XCTAssertFalse(restored.widgetUpdatesEnabled)
            XCTAssertFalse(defaults.bool(forKey: "widgetUpdatesEnabled"))
            XCTAssertTrue(restored.notificationsEnabled)
            XCTAssertEqual(restored.selectedTerminalBundleIdentifier, "com.mitchellh.ghostty")
            restored.widgetUpdatesEnabled = true
            XCTAssertTrue(Preferences(defaults: defaults).widgetUpdatesEnabled)
            XCTAssertTrue(Preferences(defaults: defaults).notificationsEnabled)
        }
    }

    func testWidgetUpdatesLoadsExplicitOffBeforeAnySetter() {
        withDefaults { defaults in
            defaults.set(false, forKey: "widgetUpdatesEnabled")
            XCTAssertFalse(Preferences(defaults: defaults).widgetUpdatesEnabled)
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
