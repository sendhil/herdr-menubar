import Foundation
import XCTest
@testable import HerdrMenubar

final class SocketPathResolverTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private let resolver = SocketPathResolver()

    func testExplicitSocketPathTakesPrecedenceOverSession() {
        let result = resolver.resolve(
            environment: ["HERDR_SOCKET_PATH": "/tmp/custom.sock", "HERDR_SESSION": "work"],
            homeDirectory: home
        )

        XCTAssertEqual(result.path, "/tmp/custom.sock")
    }

    func testNamedSessionUsesSessionSocket() {
        let result = resolver.resolve(
            environment: ["HERDR_SESSION": "work"],
            homeDirectory: home
        )

        XCTAssertEqual(result.path, "/Users/me/.config/herdr/sessions/work/herdr.sock")
    }

    func testDefaultUsesPublicHerdrSocket() {
        let result = resolver.resolve(environment: [:], homeDirectory: home)

        XCTAssertEqual(result.path, "/Users/me/.config/herdr/herdr.sock")
    }

    func testEmptyOverridesAreIgnored() {
        let result = resolver.resolve(
            environment: ["HERDR_SOCKET_PATH": "", "HERDR_SESSION": ""],
            homeDirectory: home
        )

        XCTAssertEqual(result.path, "/Users/me/.config/herdr/herdr.sock")
    }
}
