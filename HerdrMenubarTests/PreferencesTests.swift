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
