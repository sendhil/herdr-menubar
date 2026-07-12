import XCTest

@MainActor
final class HerdrMenubarUITests: XCTestCase {
    func testApplicationLaunches() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5) || app.state == .runningBackground
        )
    }
}
