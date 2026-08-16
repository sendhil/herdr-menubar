import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class SessionDiscoveryTests: XCTestCase {
    func testDiscoversDefaultAndNamedSocketsInStableOrder() async throws {
        let root = try makeRoot()
        try makeUnixSocket(at: root.appending(path: "herdr.sock"))
        try makeUnixSocket(at: root.appending(path: "sessions/work/herdr.sock"))
        try makeUnixSocket(at: root.appending(path: "sessions/alpha/herdr.sock"))

        let descriptors = try await SessionDiscovery(configRoot: root).discover()

        XCTAssertEqual(descriptors, [
            SessionDescriptor(id: .default, socketURL: root.appending(path: "herdr.sock")),
            SessionDescriptor(id: .named("alpha"), socketURL: root.appending(path: "sessions/alpha/herdr.sock")),
            SessionDescriptor(id: .named("work"), socketURL: root.appending(path: "sessions/work/herdr.sock"))
        ])
        XCTAssertEqual(descriptors.map(\.displayName), ["Default", "alpha", "work"])
    }

    func testIgnoresFilesMissingSocketsSymlinksAndDeepDescendants() async throws {
        let root = try makeRoot()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "herdr.sock"))
        try Data().write(to: root.appending(path: "sessions/not-a-directory"))
        try fileManager.createDirectory(
            at: root.appending(path: "sessions/missing-socket"),
            withIntermediateDirectories: true
        )
        try makeUnixSocket(at: root.appending(path: "sessions/deep/child/herdr.sock"))
        let realSocket = root.appending(path: "real.sock")
        try makeUnixSocket(at: realSocket)
        let symlinkDirectory = root.appending(path: "sessions/symlink")
        try fileManager.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: symlinkDirectory.appending(path: "herdr.sock"),
            withDestinationURL: realSocket
        )

        let descriptors = try await SessionDiscovery(configRoot: root).discover()

        XCTAssertEqual(descriptors, [])
    }

    func testMissingRootIsSuccessfulEmptyDiscovery() async throws {
        let root = URL(fileURLWithPath: "/tmp/hm-\(randomSuffix())", isDirectory: true)

        let descriptors = try await SessionDiscovery(configRoot: root).discover()

        XCTAssertEqual(descriptors, [])
    }

    func testAcceptsSpacesUnicodeAndDotPrefixedDirectChildNames() async throws {
        let root = try makeRoot()
        for name in ["client work", "日本語", ".scratch"] {
            try makeUnixSocket(at: root.appending(path: "sessions/\(name)/herdr.sock"))
        }

        let descriptors = try await SessionDiscovery(configRoot: root).discover()

        XCTAssertEqual(Set(descriptors.map(\.id)), [
            .named("client work"),
            .named("日本語"),
            .named(".scratch")
        ])
    }

    func testRepeatedScansReturnIdenticalDescriptorsAndOrdering() async throws {
        let root = try makeRoot()
        try makeUnixSocket(at: root.appending(path: "herdr.sock"))
        for name in ["work", "alpha", "beta"] {
            try makeUnixSocket(at: root.appending(path: "sessions/\(name)/herdr.sock"))
        }
        let discovery = SessionDiscovery(configRoot: root)

        let first = try await discovery.discover()
        let second = try await discovery.discover()
        let third = try await discovery.discover()

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        XCTAssertEqual(first.map(\.id), [.default, .named("alpha"), .named("beta"), .named("work")])
    }

    func testXDGConfigHomeSelectsConfigurationRoot() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            SessionDiscovery.configurationRoot(
                environment: ["XDG_CONFIG_HOME": "/tmp/custom-config"],
                homeDirectory: home
            ),
            URL(fileURLWithPath: "/tmp/custom-config/herdr", isDirectory: true)
        )
        XCTAssertEqual(
            SessionDiscovery.configurationRoot(environment: ["XDG_CONFIG_HOME": ""], homeDirectory: home),
            URL(fileURLWithPath: "/Users/example/.config/herdr", isDirectory: true)
        )
        XCTAssertEqual(
            SessionDiscovery.configurationRoot(environment: [:], homeDirectory: home),
            URL(fileURLWithPath: "/Users/example/.config/herdr", isDirectory: true)
        )
    }

    func testHerdrSessionAndSocketPathDoNotLimitDiscovery() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let environment = [
            "XDG_CONFIG_HOME": "/tmp/custom-config",
            "HERDR_SESSION": "work",
            "HERDR_SOCKET_PATH": "/tmp/override.sock"
        ]

        XCTAssertEqual(
            SessionDiscovery.configurationRoot(environment: environment, homeDirectory: home),
            URL(fileURLWithPath: "/tmp/custom-config/herdr", isDirectory: true)
        )
    }

    func testUnreadableSessionsDirectoryThrowsInsteadOfPretendingEmpty() async throws {
        let root = try makeRoot()
        let sessions = root.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(sessions.path, 0), 0)
        addTeardownBlock {
            _ = chmod(sessions.path, S_IRWXU)
        }

        do {
            _ = try await SessionDiscovery(configRoot: root).discover()
            XCTFail("Expected discovery to report an unreadable sessions directory")
        } catch {
            XCTAssertNotEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/hm-\(randomSuffix())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func randomSuffix() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    private func makeUnixSocket(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    destination.initialize(from: source.baseAddress!, count: pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        addTeardownBlock {
            Darwin.close(descriptor)
            Darwin.unlink(url.path)
        }
    }
}
