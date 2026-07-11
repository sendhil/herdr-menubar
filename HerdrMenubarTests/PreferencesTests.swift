import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "dev.herdr.menubar.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTerminalDefaultsToWezTerm() {
        XCTAssertEqual(
            Preferences(defaults: defaults).selectedTerminalBundleIdentifier,
            "com.github.wez.wezterm"
        )
    }

    func testSelectedTerminalPersistsInInjectedDefaults() {
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
