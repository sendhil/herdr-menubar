import Darwin
import Foundation
import XCTest
@testable import HerdrMenubar

final class HerdrConnectionTests: XCTestCase {
    func testSendAddsNewlineAndReadsSplitMultipleResponsesThroughEOF() async throws {
        let server = try UnixSocketServer()
        async let acceptedPeer = server.accept()
        let connection = try await NWHerdrConnectionFactory().connect(to: server.url)
        let peer = try await acceptedPeer
        defer { peer.close() }

        try await connection.sendLine(Data(#"{"method":"pane.list"}"#.utf8))
        XCTAssertEqual(try peer.readLine(), Data("{\"method\":\"pane.list\"}\n".utf8))

        try peer.write(Data(#"{"id":"1""#.utf8))
        try peer.write(Data("}\n{\"id\":\"2\"}\n".utf8))
        peer.finishWriting()

        let firstLine = try await connection.nextLine()
        let secondLine = try await connection.nextLine()
        let endOfStream = try await connection.nextLine()
        XCTAssertEqual(firstLine, Data(#"{"id":"1"}"#.utf8))
        XCTAssertEqual(secondLine, Data(#"{"id":"2"}"#.utf8))
        XCTAssertNil(endOfStream)
        await connection.close()
    }

    func testPreCancelledSendThrowsCancellationError() async throws {
        let server = try UnixSocketServer()
        async let acceptedPeer = server.accept()
        let connection = try await NWHerdrConnectionFactory().connect(to: server.url)
        let peer = try await acceptedPeer
        defer { peer.close() }

        let task = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Continue while the task remains cancelled to exercise sendLine's entry check.
            }
            try await connection.sendLine(Data("request".utf8))
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected a pre-cancelled send to throw")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellingWaitingReadThrowsCancellationError() async throws {
        let server = try UnixSocketServer()
        async let acceptedPeer = server.accept()
        let connection = try await NWHerdrConnectionFactory().connect(to: server.url)
        let peer = try await acceptedPeer
        defer { peer.close() }

        let readStarted = expectation(description: "read task started")
        let task = Task {
            readStarted.fulfill()
            return try await connection.nextLine()
        }
        await fulfillment(of: [readStarted], timeout: 1)
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected a cancelled read to throw")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private final class UnixSocketServer: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.herdr.menubar.tests.unix-socket")

    init() throws {
        url = URL(fileURLWithPath: "/tmp/herdr-\(UUID().uuidString).sock")
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }

        do {
            try Self.bind(descriptor, to: url.path)
            guard Darwin.listen(descriptor, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
        } catch {
            Darwin.close(descriptor)
            unlink(url.path)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
        unlink(url.path)
    }

    func accept() async throws -> UnixSocketPeer {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var pending = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&pending, 1, 2_000) > 0 else {
                    continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                    return
                }
                let peerDescriptor = Darwin.accept(self.descriptor, nil, nil)
                guard peerDescriptor >= 0 else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL))
                    return
                }
                continuation.resume(returning: UnixSocketPeer(descriptor: peerDescriptor))
            }
        }
    }

    private static func bind(_ descriptor: Int32, to path: String) throws {
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < pathCapacity else { throw POSIXError(.ENAMETOOLONG) }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { pathPointer in
                _ = strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    pathPointer,
                    pathCapacity
                )
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        address.sun_len = UInt8(addressLength)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }
}

private final class UnixSocketPeer: @unchecked Sendable {
    private let descriptor: Int32
    private var isClosed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func readLine() throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                result.append(byte)
                if byte == 0x0A { return result }
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    func finishWriting() {
        shutdown(descriptor, SHUT_WR)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    deinit {
        close()
    }
}
